import CmuxNextCompat
import os
public import CmuxNextDesign
public import CmuxNextWakeups
public import Foundation

/// What each agent chat's page held that acpmux does not (``AgentPaneWakeState``: the composer's
/// attachments, shell mode with its unrun command, where the transcript rested), by tab, in a JSON
/// file in the tag's state directory. The quit's window step saves it (`QuitCoordinator`), so every
/// relaunch that goes through the quit (Restart to Update, SIGTERM's Quit and keep sessions,
/// Cmd-Q) keeps it; the next launch reads it off the main thread from its start (``begin(on:)``, in the
/// app's `main` before `NSApplication.run`) and hands it to each tab's first page with its handshake, as a
/// woken hibernated page gets it: a page whose handshake comes before the read ends waits for it there,
/// never on the main thread. The draft's text is acpmux's and a new chat's is
/// ``AgentUnsentDrafts``'.
///
/// An attachment's contents (a pasted screenshot, a PDF, a recording, a text file's text) are copied
/// into ``attachmentsDirectoryName`` beside the JSON file as files of their own, so the JSON keeps
/// only the chips' names and kinds and no chip, whatever its size, pushes a tab past the JSON's cap
/// (Leo 2026-10-20: the draft's text came back, its screenshots did not; Leo 2026-10-26: attachments
/// take arbitrarily large files of any type). The launch reads them back and removes both, so a
/// chip sent or taken out later in that run is never saved again.
public final class AgentPaneRelaunchWake {
    public static let fileName = "agent-pane-wake-states.json"
    public static let attachmentsDirectoryName = "agent-pane-wake-attachments"
    /// The JSON (shell commands, the chips' names and kinds; never a chip's contents): a tab holding
    /// more is not kept, and the file stops growing past ``maximumBytes`` (a larger file is not read).
    nonisolated static let maximumTabBytes = 4 * 1024 * 1024
    nonisolated static let maximumBytes = 8 * 1024 * 1024
    let file: URL?
    /// Asks a live page what it holds, within the limit (``AgentPaneView/wakeState(limit:)``).
    public var read: @MainActor (AgentPaneView, Duration) async -> AgentPaneWakeState? = { await $0.wakeState(limit: $1) }

    /// Reads the saved states.
    private let reader: LaunchFileReader
    /// The launch read of the last quit's states (``begin(on:)``).
    private var launch: LaunchRead<[String: AgentPaneWakeState]>?
    /// The tabs whose launch state a page took (each once).
    private var claimed: Set<String> = []

    /// - Parameters:
    ///   - file: The JSON file; nil keeps nothing.
    ///   - reader: Reads it at launch; default from disk (tests record where it runs).
    public init(file: URL?, reader: LaunchFileReader = LaunchFileReader()) {
        self.file = file
        self.reader = reader
    }

    /// The file in the tag's state directory (beside the launch snapshot).
    public convenience init(directory: URL?) {
        self.init(file: directory?.appending(path: Self.fileName))
    }

    /// Where the attachments' files go: beside the JSON file.
    var attachmentsDirectory: URL? {
        file?.deletingLastPathComponent().appending(path: Self.attachmentsDirectoryName, directoryHint: .isDirectory)
    }

    /// One tab's state as saved: its attachments' contents moved out to files.
    nonisolated struct Saved: Codable {
        var state: AgentPaneWakeState
        /// The file in the attachments directory holding each attachment's bytes, by attachment id.
        var files: [String: String]?
        /// The file in the attachments directory holding each attachment's text, by attachment id.
        var texts: [String: String]?
    }

    /// Starts the launch read of the last quit's states (what ``take(on:)`` reads) on `work`'s files lane at
    /// once; a later call does nothing. Each tab's first page then gets its state through ``hand(_:to:)``.
    public func begin(on work: BackgroundWork) {
        guard let file, launch == nil else { return }
        let (folder, reader) = (attachmentsDirectory, reader)
        // Quit waits for it (``collect(held:pages:live:limit:)``), so it always runs, even past a quit.
        launch = LaunchRead(on: work, shutdown: .blockShutdown) {
            Self.readAndRemove(file, attachments: folder, reader: reader)
        }
    }

    /// Whether the last quit may have left tab `key` a state no page took: the launch read runs, or it
    /// left one.
    public func mayHold(_ key: String) -> Bool {
        guard let launch, !claimed.contains(key) else { return false }
        return launch.value.map { $0[key] != nil } ?? true
    }

    /// Hands tab `key`'s state from the last quit to `model`, a page with none of its own
    /// (``AgentPaneModel/pendingWake``): at once when the launch read has ended (never waiting), else
    /// through ``AgentPaneModel/wakeSource``, which the page's first `ready` awaits.
    public func hand(_ key: String, to model: AgentPaneModel) {
        guard model.pendingWake == nil, let launch, !claimed.contains(key) else { return }
        if let states = launch.value {
            claimed.insert(key)
            model.pendingWake = states[key]
        } else {
            model.wakeSource = { [weak self] in await self?.state(for: key) }
        }
    }

    /// Tab `key`'s state from the last quit, once, after the launch read.
    private func state(for key: String) async -> AgentPaneWakeState? {
        guard let launch else { return nil }
        let states = await launch.finished()
        return claimed.insert(key).inserted ? states[key] : nil
    }

    /// The last quit's states, by tab, once: the file and the attachments' files go, so a crash
    /// later in this run never brings back chips already sent. The reads (the JSON up to
    /// ``maximumBytes``, the attachments' files whatever their size), the decode and the removal run
    /// on `work`'s files lane, never on the main thread. The app's launch uses ``begin(on:)``.
    public func take(on work: BackgroundWork) async -> [String: AgentPaneWakeState] {
        guard let file else { return [:] }
        let (folder, reader) = (attachmentsDirectory, reader)
        return (try? await work.run(.userVisible, mayBlock: .files, { Self.readAndRemove(file, attachments: folder, reader: reader) })) ?? [:]
    }

    private nonisolated static func readAndRemove(_ file: URL, attachments folder: URL?, reader: LaunchFileReader) -> [String: AgentPaneWakeState] {
        defer {
            try? FileManager.checked.removeItem(at: file)
            if let folder { try? FileManager.checked.removeItem(at: folder) }
        }
        guard let data = reader.data(at: file, maximumBytes: maximumBytes) else { return [:] }
        let decoder = JSONDecoder()
        let saved = (try? decoder.decode([String: Saved].self, from: data))
            // A file the last build wrote, contents inline.
            ?? (try? decoder.decode([String: AgentPaneWakeState].self, from: data))?.mapValues { Saved(state: $0) }
            ?? [:]
        return saved.compactMapValues { saved in
            var state = saved.state
            if let folder, var attachments = state.attachments {
                if let files = saved.files {
                    attachments = AgentPaneAttachmentFiles.readBack(attachments, files: files, in: folder)
                }
                if let texts = saved.texts {
                    attachments = AgentPaneAttachmentFiles.readBack(attachments, .text, files: texts, in: folder)
                }
                state.attachments = attachments
            }
            return state.isEmpty ? nil : state
        }
    }

    /// How long a quit asks each live page for its state. The page first
    /// waits for its typed draft to reach acpmux, at most `draftSettleMs` of
    /// schemas/agent-pane/wake-state.json (500 ms), then answers with every
    /// chip's contents inline; this leaves 500 ms more for a large chip to
    /// cross the bridge. The ask outlasts the quit's composer step limit: the
    /// quit waits for that step past its limit, up to its deadline
    /// (`QuitStepLimiter.finishOverruns`). A page that does not answer keeps
    /// the state it was given, and the quit logs it.
    public static let askLimit: Duration = .seconds(1)

    /// What every chat holds for the next launch, by tab: the last quit's states no page took (after
    /// the launch read), `held` (released pages' states, by tab) over them, then each page in `pages`. A page that has not taken its state yet (no `ready`, only a
    /// reconnect) keeps it unasked; every other page is asked at once, each within `limit`, and
    /// one that does not answer keeps the tab's held state or the one its `ready` took. Tabs
    /// `live` refuses (gone from every tree) keep nothing.
    public func collect(held: [String: AgentPaneWakeState], pages: [(key: String, view: AgentPaneView)],
                        live: (String) -> Bool, limit: Duration = askLimit) async -> [String: AgentPaneWakeState] {
        let unclaimed = (await launch?.finished() ?? [:]).filter { !claimed.contains($0.key) }
        var states = unclaimed.merging(held) { _, held in held }
        let read = read
        // task-owner: every ask is awaited below, before the quit goes on.
        let asks = pages.map { page in
            (page, page.view.model.pendingWake == nil && page.view.model.hasHandshake ? Task { await read(page.view, limit) } : nil)
        }
        for (page, ask) in asks {
            let model = page.view.model
            let answer = await ask?.value
            if let ask, answer == nil, !ask.isCancelled {
                Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.relaunch-wake")
                    .error("chat \(page.key, privacy: .public) did not answer its quit ask within \(limit, privacy: .public); it keeps the state it was given")
            }
            states[page.key] = answer ?? model.pendingWake ?? states[page.key] ?? model.handedWake
        }
        return states.filter { key, state in !state.isEmpty && live(key) }
    }

    /// Replaces the saved states with `states` (by tab key); with none held the file and the
    /// attachments' files go.
    public func save(_ states: [String: AgentPaneWakeState]) async {
        guard let file, let folder = attachmentsDirectory else { return }
        let held = states.filter { !$0.value.isEmpty }
        await Task.detached { Self.write(held, to: file, attachments: folder) }.value
    }

    private nonisolated static func write(_ states: [String: AgentPaneWakeState], to file: URL, attachments folder: URL) {
        let manager = FileManager.default
        // Only this save's files stay: the last save's are gone even when a tab drops out below.
        try? manager.removeItem(at: folder)
        let encoder = JSONEncoder()
        var kept: [String: Saved] = [:]
        var total = 0
        // Every chip's contents, bytes and text, go to files of their own: the JSON keeps only
        // their names and kinds, so no chip's size counts against a tab's JSON.
        for (key, state) in states.sorted(by: { $0.key < $1.key }) {
            guard let bytes = AgentPaneAttachmentFiles.moveOut(state.attachments ?? [], to: folder),
                  let texts = AgentPaneAttachmentFiles.moveOut(bytes.attachments, .text, to: folder) else { continue }
            var held = state
            if state.attachments != nil { held.attachments = texts.attachments }
            let saved = Saved(state: held, files: bytes.files.isEmpty ? nil : bytes.files, texts: texts.files.isEmpty ? nil : texts.files)
            guard let size = (try? encoder.encode(saved))?.count, size <= maximumTabBytes, total + size <= maximumBytes else { continue }
            kept[key] = saved
            total += size
        }
        guard !kept.isEmpty, let data = try? encoder.encode(kept) else {
            try? manager.removeItem(at: file)
            try? manager.removeItem(at: folder)
            return
        }
        try? data.write(to: file, options: .atomic)
        let referenced = Set(kept.values.flatMap { Array(($0.files ?? [:]).values) + Array(($0.texts ?? [:]).values) })
        if referenced.isEmpty { try? manager.removeItem(at: folder) }
        // A tab that did not fit wrote files nothing names: they go.
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where !referenced.contains(name) {
            try? manager.removeItem(at: folder.appending(path: name))
        }
    }
}
