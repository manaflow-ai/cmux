import CmuxNextCompat
public import CmuxNextWakeups
import Darwin
public import Foundation
import os

/// Writes this launch's ``LaunchTimesRecord`` once, off the main thread (CMUX-571). The app's composition
/// root makes one per launch and calls ``write(marks:)`` when the first window frame and Home's reveal are
/// both marked; the write also logs the line at `.notice`, which a release build keeps. From its making it
/// listens to the launch marks (its `listen`) and writes the row again, once, when the prior
/// chat's marks are in (``heard(_:marks:)``, CMUX-119).
public nonisolated struct LaunchTimesRecorder: Sendable {
    /// When this process started (`sysctl` `KERN_PROC_PID`): the launch marks' zero.
    public static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    let file: LaunchTimesFile
    let work: BackgroundWork
    let version: String, build: String, commit: String?
    /// Whether the updater pre-warmed `build` before this launch (consumes its marker). Blocking.
    let prewarmed: @Sendable (_ build: String) -> Bool
    /// The one rewrite of this launch's row with the prior chat's columns (CMUX-119), and the lock its file writes take.
    let priorChat = LaunchPriorChatWatch()
    /// Each launch binder's milliseconds (``LaunchTimesRecord/binders``).
    let binders: @Sendable () -> [String: Double]

    /// - Parameters:
    ///   - info: the bundle's Info.plist (`CFBundleShortVersionString`, `CFBundleVersion`, `CMUXCommit`).
    ///   - listen: registers a listener for the names of the launch marks to come (the agent pane's, which the
    ///     prior chat's are); `marks` reads every launch mark so far.
    public init(file: LaunchTimesFile, work: BackgroundWork, info: [String: Any],
                listen: (@escaping @Sendable (String) -> Void) -> Void = { _ in }, marks: @escaping @Sendable () -> [String: Double] = { [:] },
                binders: @escaping @Sendable () -> [String: Double] = { [:] },
                prewarmed: @escaping @Sendable (_ build: String) -> Bool) {
        self.file = file
        self.work = work
        version = info["CFBundleShortVersionString"] as? String ?? ""
        build = info["CFBundleVersion"] as? String ?? ""
        commit = info["CMUXCommit"] as? String
        self.prewarmed = prewarmed
        self.binders = binders
        let recorder = self
        listen { recorder.heard($0, marks: marks) }
        // The frame may have committed after the front chat painted and connected.
        // Subscribe first so a mark arriving during this check is covered too.
        recorder.heard(LaunchPriorChat.frontMark, marks: marks)
    }

    /// Writes the record of this launch with `marks` (milliseconds since ``processStart``) on a files lane: appends
    /// it, or rewrites this launch's row when it is written already (``LaunchTimesFile/append(_:rewritingLast:)``).
    /// `workspaces`: the workspaces the launch restored; nil on the prior chat's rewrite, which keeps the row's.
    public func write(marks: [String: Double], workspaces: Int? = nil) {
        let recorder = self
        work.post(.bestEffort, mayBlock: .files) {
            let log = Logger(subsystem: "com.cmuxterm.app.next", category: "launch")
            do {
                let line = try recorder.priorChat.writing(prewarmed: { recorder.prewarmed(recorder.build) }) { prewarmed, written in
                    try recorder.file.append(LaunchTimesRecord(marks: marks, startedAt: Self.processStart, version: recorder.version,
                                                               build: recorder.build, commit: recorder.commit, prewarmed: prewarmed,
                                                               workspaces: workspaces, binders: recorder.binders()),
                                             rewritingLast: written)
                }
                log.notice("launch-times \(line, privacy: .public)")
            } catch {
                log.error("launch-times not written: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Hears launch mark `name` (its `listen`): on the mark that completes the prior chat's
    /// (``LaunchPriorChat/marks``) when the restored front tab is a chat, writes this launch's row again with
    /// them, once. It never waits on Home's reveal: a relaunch into a chat workspace never shows Home.
    public func heard(_ name: String, marks: () -> [String: Double]) {
        if let marks = priorChat.complete(after: name, marks: marks) { write(marks: marks) }
    }
}

/// The prior chat's launch columns (CMUX-119), on the launch marks' clock. Leo, 2026-11-16: "when i
/// restart/re-launch... im expecting my prior workspace and the probable agent chat session that i had
/// running. so THAT's the importtnt one". The marks are the ones the quit-reopen harness reads
/// (scripts/ci/quit_gamut_check.py): `agent_pane.painted`, the chat's page drawn with its recent messages, and
/// `agent_pane.transport_open`, its stream connected; ``frontMark`` says the chat was the tab in front.
public nonisolated struct LaunchPriorChat {
    public nonisolated init() {}
    /// An agent chat (not a new tab's page) went on screen before the launch's pane region was ready: the
    /// restored front tab is a chat (`AgentPaneView.viewDidMoveToWindow`).
    public static let frontMark = "launch.front_chat_shown"
    /// The marks both columns need.
    public static let marks: Set<String> = [frontMark, "agent_pane.painted", "agent_pane.transport_open"]

    /// (the chat in front and drawn, the same chat live: drawn and its stream open); nil unless every one of
    /// ``marks`` is in `marks`.
    public static func times(_ marks: [String: Double]) -> (painted: Double, live: Double)? {
        guard let front = marks[frontMark], let painted = marks["agent_pane.painted"],
              let open = marks["agent_pane.transport_open"] else { return nil }
        let shown = max(front, painted)
        return (shown, max(shown, open))
    }
}

/// The once of a launch's prior-chat rewrite, and the lock that keeps its row's writes one at a time.
public nonisolated final class LaunchPriorChatWatch: Sendable {
    private let claimed = Mutex(false)
    /// Held by every write of the row: the build's pre-warm answer, read on the first write, and whether the row is written.
    private let files = Mutex<(prewarmed: Bool?, written: Bool)>((nil, false))

    public init() {}

    /// `marks()` when `name` is one of ``LaunchPriorChat/marks`` and they are all in, the first time only; nil otherwise.
    public func complete(after name: String, marks: () -> [String: Double]) -> [String: Double]? {
        guard LaunchPriorChat.marks.contains(name), !claimed.withLock({ $0 }) else { return nil }
        let marks = marks()
        guard LaunchPriorChat.times(marks) != nil, claimed.withLock({ claimed in defer { claimed = true }; return !claimed }) else { return nil }
        return marks
    }

    /// Runs `write` alone, so the first write and the rewrite never race on the file, with whether the build was
    /// pre-warmed (`prewarmed` is asked on the first write only: it consumes its marker) and whether the row is written.
    func writing(prewarmed: () -> Bool, _ write: (_ prewarmed: Bool, _ written: Bool) throws -> String) throws -> String {
        try files.withLock { state in
            let warmed = state.prewarmed ?? prewarmed()
            state.prewarmed = warmed
            let line = try write(warmed, state.written)
            state.written = true
            return line
        }
    }
}

/// One launch's times, as `cmux app launch-times` prints them (CMUX-571). Every build writes it,
/// release and NIGHTLY included: the launch marks themselves live only in memory and `debug.timings`
/// answers only in a debug build, so a release launch was unmeasurable after the fact.
///
/// The milliseconds are on the launch marks' clock (since the process started, `DebugTimings`).
public nonisolated struct LaunchTimesRecord: Codable, Equatable, Sendable {
    /// When the process started (ISO 8601, UTC).
    public var startedAt: String
    /// `CFBundleShortVersionString`.
    public var version: String
    /// `CFBundleVersion`.
    public var build: String
    /// `CMUXCommit`; nil in a build that has none.
    public var commit: String?
    /// Process start to `main` (`main_start`): exec, dyld, static initializers.
    public var preMainMs: Double?
    /// `main` to the first window frame committed.
    public var mainMs: Double?
    /// Process start to the first window frame committed (`first_window_frame_committed`).
    public var firstWindowFrameMs: Double?
    /// Process start to Home's first page on screen: its page in its dock, drawn from its saved state
    /// (`home.saved_page_shown`), else the Chief's first page (`home.first_page`, classic Home); nil when
    /// Home showed by its deadline first.
    public var homeFirstPageMs: Double?
    /// What showed Home: `mark` (its first page came) or `deadline` (``LaunchReveal``'s deadline passed first).
    public var homeRevealedBy: String?
    /// Process start to the window taking keys (`window_usable`): Home's message field has the keyboard in the key
    /// window. Nil when it had not by the time the record was written (the keyboard went elsewhere, no Home).
    public var windowUsableMs: Double?
    /// Process start to the first live output of a shell this launch (`first_shell_live`), when one came before the record.
    public var firstShellLiveMs: Double?
    /// The launch found no launch snapshot (`launch.no_snapshot`): nothing saved to show, a fresh install's launch.
    /// Nil in records written before this field.
    public var noSnapshot: Bool?
    /// Process start to the restored front tab's agent chat on screen, drawn with its recent messages
    /// (`agent_pane.painted`); nil when the front tab is not a chat or it has not drawn yet (``LaunchPriorChat``).
    public var priorChatPaintedMs: Double?
    /// Process start to that chat live too: drawn and its stream connected (`agent_pane.transport_open`).
    public var priorChatLiveMs: Double?
    /// The updater pre-warmed this build before this launch (`StagedUpdatePrewarm`): this is the first
    /// launch of a build the running app ran once while the update waited.
    public var prewarmed: Bool
    /// The launch before this one (in the file) was another build or there was none: the first launch of
    /// this bundle's build, so likely the first exec of its files.
    public var firstLaunchOfBuild: Bool
    /// Process start to each of ``phaseMarks`` this launch reached, by mark name; nil in a row written before
    /// it. A regression names its phase from the file alone (2026-11-16: main to first frame, 650 to 1900 ms).
    public var phases: [String: Double]?
    /// Process start to each of the launch's stages this launch reached (``LaunchStages``), by stage name: the
    /// per-stage startup times (startup-tti). Nil in a row written before it.
    public var stages: [String: Double]?
    /// `cold`: the first launch of this build's files, not pre-warmed; `warm`: any other. Set by
    /// ``LaunchTimesFile/append(_:rewritingLast:)``; nil in a row written before it.
    public var launchKind: String?
    /// The workspaces the launch restored; nil when the launch did not say.
    public var workspaces: Int?
    /// The launch started the daemon (`daemon.spawned`: true, its spawn is in the launch's time) or connected to one
    /// already running (`daemon.reused`: false), whichever came first; nil when neither was marked.
    public var daemonSpawned: Bool?
    /// The ``binderCount`` slowest binders of the launch's `AppActions.bind`, each its main-thread milliseconds, by
    /// binder (startup-under-100ms: which binders the pre-frame cut defers). Nil in a row written before it.
    public var binders: [String: Double]?
    /// The binders a row keeps.
    public static let binderCount = 16

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at", version, build, commit
        case preMainMs = "pre_main_ms", mainMs = "main_ms", firstWindowFrameMs = "first_window_frame_ms"
        case homeFirstPageMs = "home_first_page_ms", homeRevealedBy = "home_revealed_by"
        case windowUsableMs = "window_usable_ms", firstShellLiveMs = "first_shell_live_ms", noSnapshot = "no_snapshot"
        case priorChatPaintedMs = "prior_chat_painted_ms", priorChatLiveMs = "prior_chat_live_ms"
        case prewarmed, firstLaunchOfBuild = "first_launch_of_build", phases
        case stages, launchKind = "launch_kind", workspaces, daemonSpawned = "daemon_spawned", binders
    }

    /// The record of a launch whose marks are `marks` (name to milliseconds since process start).
    /// ``firstLaunchOfBuild`` is set by ``LaunchTimesFile/append(_:)``, which knows the launch before.
    public init(marks: [String: Double], startedAt: Date, version: String, build: String, commit: String?, prewarmed: Bool,
                workspaces: Int? = nil, binders: [String: Double] = [:]) {
        func round(_ ms: Double?) -> Double? { ms.map { ($0 * 10).rounded() / 10 } }
        self.startedAt = startedAt.formatted(.iso8601)
        self.version = version
        self.build = build
        self.commit = commit
        preMainMs = round(marks["main_start"])
        firstWindowFrameMs = round(marks["first_window_frame_committed"])
        if let main = marks["main_start"], let frame = marks["first_window_frame_committed"] { mainMs = round(frame - main) }
        homeFirstPageMs = round(marks["home.saved_page_shown"] ?? marks["home.first_page"])
        if marks["reveal.home"] != nil { homeRevealedBy = marks["reveal.home.by_deadline"] != nil ? "deadline" : "mark" }
        windowUsableMs = round(marks["window_usable"])
        firstShellLiveMs = round(marks["first_shell_live"])
        noSnapshot = marks["launch.no_snapshot"] != nil
        if let chat = LaunchPriorChat.times(marks) { (priorChatPaintedMs, priorChatLiveMs) = (round(chat.painted), round(chat.live)) }
        let phases = marks.filter { Self.phaseMarks.contains($0.key) }.mapValues { ($0 * 10).rounded() / 10 }
        self.phases = phases.isEmpty ? nil : phases
        let stages = LaunchStages.spans(marks).mapValues { ($0 * 10).rounded() / 10 }
        self.stages = stages.isEmpty ? nil : stages
        self.workspaces = workspaces
        daemonSpawned = Self.daemonSpawned(marks)
        let slowest = binders.sorted { $0.value > $1.value }.prefix(Self.binderCount)
        self.binders = slowest.isEmpty ? nil : Dictionary(uniqueKeysWithValues: slowest.map { ($0.key, (($0.value * 100).rounded() / 100)) })
        self.prewarmed = prewarmed
        firstLaunchOfBuild = true
    }

    /// Whether the launch's daemon was spawned (true) or reused (false): the earlier of its two marks; nil with neither.
    static func daemonSpawned(_ marks: [String: Double]) -> Bool? {
        switch (marks["daemon.spawned"], marks["daemon.reused"]) {
        case let (spawned?, reused?): spawned <= reused
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): nil
        }
    }

    /// The marks the record waits for before it is written: the first window frame and Home's reveal.
    public static let awaitedMarks = ["first_window_frame_committed", "reveal.home"]

    /// The launch marks a row keeps under ``phases``, in launch order (`cmux app launch-times --phases`).
    /// Every launch mark a stage splits into is here, so a stage's regression names its step from the file alone,
    /// outside a harness's marks pipe too (startup-tti, 2026-11-21).
    public static let phaseMarks = [
        "premain.first_initializer", "main.setup_done", "main.warmup_started",
        "main.environment", "main.state_folder", "main.reads_started", "main.crash_handlers", "main.nsapp_made", "main.launch_shell_made", "main.delegate.fields", "main.control.fields", "main.delegate.first_frame_gate", "main.delegate.main_work", "main.delegate.control", "main.delegate_made", "main.nsapp", "main.run", "app.did_finish_launching_entry", "app.launch_snapshot_awaited",
        "cloud_env.start", "cloud_env.cli_exited", "cloud_env.awaited",
        "did_finish_launching_start", "dfl.settings_read", "dfl.theme", "dfl.services", "dfl.app_actions", "dfl.bind", "dfl.settings", "dfl.menu",
        "daemon.prepare_start", "daemon.binary_resolved", "daemon.spawned", "daemon.reused", "daemon.prepare_end", "daemon.socket_connected", "daemon_connected",
        "dfl.daemon_cloud_updater", "dfl.first_window_hooks", "dfl.home_history",
        "launch_snapshot_applied", "launch_snapshot_shown", "window.make_start", "window.sidebar_made", "window.root_made", "window.shell_made", "window.content_installed", "window.backdrop_applied",
        "window.init_done", "window.configured", "window.workspace_shown", "window.ordered_front",
        "dfl.windows", "did_finish_launching_end", "window.restore_wait_start", "window.restore_wait_end",
        "frame.commit_start", "daemon_snapshot_loaded", "connecting_view_shown", "connecting_view_left", "workspace_content_shown",
        "sidebar_rows_shown", "first_window_flushed", "pages.deferred_until_frame", "agent_pane.launch_image_shown",
        "first_terminal_surface_created", "first_terminal_content", "first_terminal_content_applied", "first_terminal_frame",
        "cef.initialize_start", "chromium_page.make_start", "chromium_page.browser_created", "home.page_host_made",
        "pages.created", "cef.ready", "first_page.navigation_start", "first_page.dom_content_loaded", "first_page.first_contentful_paint", "agent_pane.view_created", "agent_pane.transport_open", "browser_pane.first_paint", "browser_pane.input_ready",
        "first_key_down", "terminal_input_accepted", "terminal_echo", "reveal.sidebar", "reveal.home",
    ]
}

/// The stages of a launch (startup-tti), each the time from process start (`sysctl` `p_starttime`, the launch
/// marks' clock) to the earliest of its marks this launch reached. Leo, 2026-11-21: "you can build instrumentation if
/// you havent already to properly measure each part of startup times." The launch harnesses compute the same stages
/// from the same marks (scripts/ci/launch_stages.py, scripts/measure/launch-ready.swift); a test keeps the three
/// tables equal.
public nonisolated struct LaunchStages {
    public nonisolated init() {}
    /// (stage, its marks), in launch order. A stage is the earliest of its marks that came.
    public static let table: [(stage: String, marks: [String])] = [
        // exec and dyld (every image mapped and bound, the system libraries' initializers) to the app's first initializer
        ("dyld", ["premain.first_initializer"]),
        ("premain", ["main_start"]), // exec, dyld, static initializers
        ("main_setup", ["main.setup_done"]), // malloc zone, signals, environment, SingleInstanceGuard
        ("did_finish_launching", ["did_finish_launching_start"]), // main to the app delegate
        ("daemon_connected", ["daemon_connected"]),
        ("first_window_shown", ["launch_snapshot_shown", "first_window_flushed", "dfl.windows"]),
        ("first_frame", ["first_window_frame_committed"]),
        ("webview_ready", ["cef.ready"]),
        // The first cmux page's own timeline (LaunchFirstPage): its navigation start, DOMContentLoaded, first contentful paint.
        ("first_page_navigation", ["first_page.navigation_start"]),
        ("first_page_dom_content_loaded", ["first_page.dom_content_loaded"]),
        ("first_page_contentful_paint", ["first_page.first_contentful_paint"]),
        ("first_chat_paint", ["agent_pane.painted", "agent_pane.newtab_painted", "home.saved_page_shown", "home.first_page"]),
        // The front Chromium tab a person opened presented its first frame (CEFLaunchMarks, CmuxNextBrowser).
        ("first_browser_paint", ["browser_pane.first_paint"]),
        // A terminal echoed a typed key, a chat composer drew one, or Home's composer has the keyboard in the key window.
        ("first_interaction", ["terminal_echo", "agent_pane.input_echoed", "window_usable"]),
    ]

    /// Stage name to ms from process start, for each stage one of whose marks is in `marks`.
    public static func spans(_ marks: [String: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (stage, names) in table {
            let reached = marks.filter { names.contains($0.key) && $0.value.isFinite && $0.value >= 0 }.values
            if let first = reached.min() { out[stage] = first }
        }
        return out
    }
}

/// `~/Library/Application Support/<bundle id>/launch-times.jsonl`: one ``LaunchTimesRecord`` per
/// line, the last ``capacity`` launches, oldest first. Each append rewrites the file (atomically)
/// with at most ``capacity`` lines, so it never grows; a file past ``maximumBytes`` (not one this
/// writes) is started over. Blocking: call it on a files lane.
public nonisolated struct LaunchTimesFile: Sendable {
    public static let fileName = "launch-times.jsonl"
    /// The launches kept.
    public static let capacity = 50
    /// Larger than `capacity` records can be: anything bigger is not this file's and is not read.
    static let maximumBytes = 256 * 1024

    public let url: URL
    public let capacity: Int

    public init(url: URL, capacity: Int = LaunchTimesFile.capacity) {
        self.url = url
        self.capacity = max(1, capacity)
    }

    /// `<bundle id>`'s folder of Application Support.
    public static func supportDirectory(bundleID: String) -> URL {
        let support = FileManager().urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager().homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return support.appending(path: bundleID, directoryHint: .isDirectory)
    }

    /// The app's file; nil in a test process (`swift test`, XCTest hosts), so no test writes the person's file.
    public static func app(bundleID: String, process: ProcessInfo = .processInfo) -> LaunchTimesFile? {
        let environment = process.environment
        if ["swiftpm-testing-helper", "xctest"].contains(process.processName)
            || ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains(where: environment.keys.contains) {
            return nil
        }
        return LaunchTimesFile(url: supportDirectory(bundleID: bundleID).appending(path: fileName))
    }

    /// The records in the file, oldest first; lines that do not parse are skipped.
    public func records() -> [LaunchTimesRecord] {
        lines().compactMap { try? JSONDecoder().decode(LaunchTimesRecord.self, from: Data($0.utf8)) }
    }

    /// Appends `record`, keeping the last ``capacity`` lines. Sets its ``LaunchTimesRecord/firstLaunchOfBuild``
    /// from the launch before. With `rewritingLast`, a last line of the same launch (start and build) is replaced
    /// instead, keeping the prior chat's columns it has and `record` lacks. Returns the line written.
    @discardableResult
    public func append(_ record: LaunchTimesRecord, rewritingLast: Bool = false) throws -> String {
        var record = record
        var earlier = lines()
        if rewritingLast, let last = earlier.last.flatMap({ try? JSONDecoder().decode(LaunchTimesRecord.self, from: Data($0.utf8)) }),
           last.startedAt == record.startedAt, last.build == record.build, last.commit == record.commit {
            earlier.removeLast()
            record.priorChatPaintedMs = record.priorChatPaintedMs ?? last.priorChatPaintedMs
            record.priorChatLiveMs = record.priorChatLiveMs ?? last.priorChatLiveMs
            record.workspaces = record.workspaces ?? last.workspaces
        }
        if let last = earlier.last.flatMap({ try? JSONDecoder().decode(LaunchTimesRecord.self, from: Data($0.utf8)) }) {
            record.firstLaunchOfBuild = last.version != record.version || last.build != record.build || last.commit != record.commit
        }
        record.launchKind = record.firstLaunchOfBuild && !record.prewarmed ? "cold" : "warm"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line = String(decoding: try encoder.encode(record), as: UTF8.self)
        let kept = earlier.suffix(capacity - 1) + [line]
        try FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((kept.joined(separator: "\n") + "\n").utf8).blockingWrite(to: url, options: .atomic)
        return line
    }

    private func lines() -> [String] {
        guard let data = try? Data(blockingContentsOf: url), data.count <= Self.maximumBytes else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

/// Each binder's main-thread time in the launch's `AppActions.bind` (startup-under-100ms: the bind leg is 70 to 83 ms
/// of the pre-frame time, and the cut defers the binders no setting or first-frame view reads). One lap per binder on
/// one clock read each; the launch-times row keeps the slowest (``LaunchTimesRecord/binders``), so one launch of any
/// build, NIGHTLY included, names them without a harness's marks pipe (which keeps 80 marks).
public nonisolated final class LaunchBinderLaps: Sendable {
    private let state = Mutex<(last: ContinuousClock.Instant, times: [String: Double])>((ContinuousClock.now, [:]))

    public init() {}

    /// The time since the previous lap (or the making) as `name`'s; a name lapped twice adds up.
    public func lap(_ name: String) {
        let now = ContinuousClock.now
        state.withLock { state in
            let elapsed = state.last.duration(to: now).components
            state.times[name, default: 0] += Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            state.last = now
        }
    }

    /// Each binder's milliseconds so far.
    public func times() -> [String: Double] { state.withLock { $0.times } }
}
