import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// A staged update's first launch, paid while the person still works in the running build
/// (goal next-launch-instant, CMUX-571).
///
/// The first exec of an executable file no process has run yet costs macOS far more than a
/// relaunch of the same file: on a pool mini, a new copy of NIGHTLY reached `main_start` in
/// 1194 ms against 45 ms for the same copy relaunched (scripts/measure/nightly-fresh-launch.sh).
/// Sparkle 2's installer puts a staged update in place with a rename on the same volume
/// (`SUPlainInstaller`, `swapItemAtURL`), so the files the pre-warm ran are the files the first
/// launch after the update runs. Measured (nightly-fresh-launch arms=prewarm, pool mini, 3 rounds): a copy
/// pre-warmed this way and then renamed reached Home's first page in 1281 ms against 4688 ms for a cold
/// copy and 3984 ms for one only `gktool scan`ned, as Sparkle does (a full launch first: 1303 ms).
///
/// What runs, one after another, each stopped after `timeout`: the staged app's executable with
/// ``argument`` (`CmuxNextApp.main()` exits on it before anything else, so exec, dyld and static
/// initializers run and nothing more), then the bundled `cmux` and `cmux-tui` with `--version`, then
/// each Chromium helper app with `--version` (the first loads the CEF framework, about 1.4 s).
/// Nothing is written, verified or skipped: Gatekeeper, quarantine and the code signature checks
/// run as they always do, only earlier.
public nonisolated struct StagedUpdatePrewarm: Equatable, Sendable {
    /// The argument a pre-warm starts the staged app with.
    public static let argument = "--cmux-prewarm-launch"

    /// Whether `arguments` (the process's, executable first) start a pre-warm.
    public static func isPrewarm(_ arguments: [String]) -> Bool {
        arguments.dropFirst().first == argument
    }

    /// The bundled executables run once with `--version` (`Contents/Resources/bin`).
    public static let bundledExecutables = ["cmux", "cmux-tui"]

    /// One process the pre-warm starts.
    public struct Run: Equatable, Sendable {
        public var executable: URL
        public var arguments: [String]
    }

    /// Sparkle's staged installation folder (``UpdateInstallPreflight/stagedInstallation(bundleIdentifier:)``).
    public let installation: URL
    public let bundleIdentifier: String
    /// The staged build (`CFBundleVersion`).
    public let build: String

    public init(installation: URL, bundleIdentifier: String, build: String) {
        self.installation = installation
        self.bundleIdentifier = bundleIdentifier
        self.build = build
    }

    /// The staged bundle of ``build``, or nil. Sparkle 2's installer extracts each update two
    /// folders under the installation folder (`Installation/<unique>/<unique>/<name>.app`,
    /// `AppInstaller`); the newest bundle with this bundle id and build wins. Blocking: reads folders.
    public func stagedBundle() -> URL? {
        let files = FileManager.checked, keys: [URLResourceKey] = [.contentModificationDateKey]
        func children(_ url: URL) -> [URL] {
            (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }
        let candidates = children(installation).flatMap(children).flatMap(children).filter { url in
            guard url.pathExtension == "app", let info = Self.info(url) else { return false }
            return info["CFBundleIdentifier"] as? String == bundleIdentifier && info["CFBundleVersion"] as? String == build
        }
        func modified(_ url: URL) -> Date {
            (try? url.blockingResourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
        }
        return candidates.max { modified($0) < modified($1) }
    }

    /// What runs for `bundle`: its executable with ``argument``, then each bundled executable
    /// that is there. Blocking: reads the bundle.
    public func runs(bundle: URL) -> [Run] {
        let files = FileManager.checked
        var runs: [Run] = []
        if let name = Self.info(bundle)?["CFBundleExecutable"] as? String {
            let executable = bundle.appending(path: "Contents/MacOS").appending(path: name)
            if files.isExecutableFile(atPath: executable.path) { runs.append(Run(executable: executable, arguments: [Self.argument])) }
        }
        for name in Self.bundledExecutables {
            let executable = bundle.appending(path: "Contents/Resources/bin").appending(path: name)
            if files.isExecutableFile(atPath: executable.path) { runs.append(Run(executable: executable, arguments: ["--version"])) }
        }
        // Each Chromium helper app (`<App> Helper (Kind).app`, named after its bundle): with no `--type` it loads the
        // CEF framework and returns (CEFShim/src/helper_main.mm), so the framework's first load is paid here too.
        let frameworks = bundle.appending(path: "Contents/Frameworks")
        let helpers = ((try? files.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "app" && $0.lastPathComponent.contains(" Helper") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for helper in helpers {
            let name = helper.deletingPathExtension().lastPathComponent
            let executable = helper.appending(path: "Contents/MacOS").appending(path: name)
            if files.isExecutableFile(atPath: executable.path) { runs.append(Run(executable: executable, arguments: ["--version"])) }
        }
        return runs
    }

    /// Finds the staged bundle on `work`'s files lane, then starts each run (``AsyncProcess``, nothing
    /// waits on a thread). `progress` gets a line for the update log once the scan ends and as each run
    /// ends, so a pre-warm cut short by the relaunch still says how far it got. Returns the last line.
    ///
    /// The scan runs at ``WorkPriority/userVisible``, not best effort: the files lane has one serial slot
    /// per priority, and the best-effort one holds the rollback keep the same staging starts (a clone of the
    /// running app, then a signature read of every kept build) and whatever else waits there. A scan queued
    /// behind them ran after the person's click or never (Leo's NIGHTLY: staged 22:38:18Z, kept 22:38:45Z,
    /// clicked 22:39:16Z, no pre-warm line). The scan reads three folder levels and some Info.plists.
    ///
    /// With `marker`, a pre-warm that found the staged bundle replaces it at each ``Step``: ``Step/started`` before
    /// the first run, ``Step/main`` once the staged app's executable ran, ``Step/full`` at the end. That build's first
    /// launch reads it (``consumeLaunchVerdict(build:at:)``) and records whether it was pre-warmed and how far
    /// (`cmux app launch-times`), so a pre-warm the relaunch cut short says where. Each write runs at
    /// ``WorkPriority/userVisible`` too, for the same reason as the scan.
    public func perform(work: BackgroundWork, processes: AsyncProcess = AsyncProcess(),
                        timeout: Duration = .seconds(20), marker: URL? = nil,
                        progress: (@Sendable (String) -> Void)? = nil) async -> String {
        let asked = ContinuousClock.now
        let scanned = try? await work.run(.userVisible, mayBlock: .files) { [self] () -> (URL, [Run])? in
            stagedBundle().map { ($0, runs(bundle: $0)) }
        }
        let scan = Self.milliseconds(ContinuousClock.now - asked)
        guard let staged = scanned ?? nil else {
            return "launch pre-warm: no staged bundle of \(build) in \(installation.path) (scan \(scan) ms)"
        }
        let bundle = staged.0, planned = staged.1
        progress?("launch pre-warm of \(build): \(planned.count) runs in \(bundle.lastPathComponent) (scan \(scan) ms)")
        let markerBuild = build
        func mark(_ step: Step) async {
            guard let marker else { return }
            try? await work.run(.userVisible, mayBlock: .files) { Self.writeLaunchMarker(build: markerBuild, step: step, at: marker) }
        }
        await mark(.started)
        var parts: [String] = []
        for run in planned {
            let started = ContinuousClock.now
            let status: String
            do {
                let outcome = try await processes.run(ProcessRequest(run.executable, run.arguments, timeout: timeout))
                status = "exit \(outcome.status)"
            } catch {
                status = "failed (\(error))"
            }
            let part = "\(run.executable.lastPathComponent) \(status) \(Self.milliseconds(ContinuousClock.now - started)) ms"
            progress?("launch pre-warm of \(build): \(part)")
            parts.append(part)
            // The main executable's run alone takes almost all of the first launch's check (measured: 201/138/132 ms
            // against 2258/2067/2039 ms cold, and 136/143/136 ms after every run), so a pre-warm cut short after it counts.
            if run.arguments == [Self.argument] { await mark(.main) }
        }
        await mark(.full)
        return "launch pre-warm of \(build) (\(bundle.lastPathComponent)): "
            + (parts.isEmpty ? "nothing to run" : parts.joined(separator: ", ") + "; \(Self.milliseconds(ContinuousClock.now - asked)) ms in all")
    }

    /// Whole milliseconds of `duration`.
    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    /// How far a pre-warm of a build got, as its marker says: ``started`` before the first run, ``main`` once the
    /// staged app's own executable ran, ``full`` after every run, or ``skipped(_:)`` with why it never ran.
    public enum Step: Equatable, Sendable {
        case started, main, full
        case skipped(String)
    }

    /// What a build's launch reads from the marker (Rust's `marker.verdict`): whether it was pre-warmed and why
    /// (`main`, `full`, `full_legacy`, `started_not_finished`, `skipped:<why>`, `other_build:<b>`, `no_record`, `no_build`).
    public struct Verdict: Equatable, Sendable {
        public var preWarmed: Bool
        public var reason: String
        /// The marker is this build's: the launch removes it.
        public var consume: Bool
        /// What `launch-times.jsonl` records: `prewarmed` and `prewarm_reason`.
        public var record: (preWarmed: Bool, reason: String) { (preWarmed, reason) }

        public init(preWarmed: Bool, reason: String, consume: Bool) {
            self.preWarmed = preWarmed
            self.reason = reason
            self.consume = consume
        }
    }

    /// `~/Library/Application Support/<bundle id>/launch-prewarm`: how far the last pre-warm of a build got,
    /// until that build's first launch consumes it. One line, replaced by each step.
    public static func launchMarkerURL(bundleIdentifier: String) -> URL {
        let support = FileManager().urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager().homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return support.appending(path: bundleIdentifier, directoryHint: .isDirectory).appending(path: "launch-prewarm")
    }

    /// Replaces `marker` with `build`'s line at `step`, atomically: a cut write leaves the step before, never part
    /// of a line. Blocking. A failure leaves the marker as it was.
    static func writeLaunchMarker(build: String, step: Step, at marker: URL) {
        guard let line = UpdatePrewarmRules.markerLine(build: build, step: step) else { return }
        try? FileManager.checked.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(line.utf8).blockingWrite(to: marker, options: .atomic)
    }

    /// What the marker says of `build`'s launch (``Verdict``); a marker of this build is then removed, so a
    /// relaunch of the same build reads `no_record`. A marker of another build (a staged update not installed
    /// yet) stays. Blocking.
    public static func consumeLaunchVerdict(build: String, at marker: URL) -> Verdict {
        let text = (try? Data(blockingContentsOf: marker)).map { String(decoding: $0, as: UTF8.self) }
        let verdict = UpdatePrewarmRules.verdict(build: build, marker: text)
        if verdict.consume { try? FileManager.checked.removeItem(at: marker) }
        return verdict
    }

    /// ``consumeLaunchVerdict(build:at:)`` at the app's own marker (``launchMarkerURL(bundleIdentifier:)``).
    public static func consumeLaunchVerdict(build: String, bundleIdentifier: String) -> Verdict {
        consumeLaunchVerdict(build: build, at: launchMarkerURL(bundleIdentifier: bundleIdentifier))
    }

    /// A bundle's Info.plist, or nil.
    static func info(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(blockingContentsOf: bundle.appending(path: "Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
