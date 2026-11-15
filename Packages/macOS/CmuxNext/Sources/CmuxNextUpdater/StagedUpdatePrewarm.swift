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

    /// Finds the staged bundle on `work`'s files lane at best-effort priority, then starts each run
    /// (``AsyncProcess``, nothing waits on a thread). Returns a line for the update log.
    public func perform(work: BackgroundWork, processes: AsyncProcess = AsyncProcess(),
                        timeout: Duration = .seconds(20)) async -> String {
        let scanned = try? await work.run(.bestEffort, mayBlock: .files) { [self] () -> (URL, [Run])? in
            stagedBundle().map { ($0, runs(bundle: $0)) }
        }
        guard let staged = scanned ?? nil else { return "launch pre-warm: no staged bundle of \(build) in \(installation.path)" }
        let bundle = staged.0, planned = staged.1
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
            let elapsed = (ContinuousClock.now - started).components
            parts.append("\(run.executable.lastPathComponent) \(status) \(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000) ms")
        }
        return "launch pre-warm of \(build) (\(bundle.lastPathComponent)): " + (parts.isEmpty ? "nothing to run" : parts.joined(separator: ", "))
    }

    /// A bundle's Info.plist, or nil.
    static func info(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(blockingContentsOf: bundle.appending(path: "Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
