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
/// each Chromium helper app with `--version` (the first loads the CEF framework, about 1.4 s), then every
/// page of `Contents/Frameworks` read once (``readPages(under:)``), the framework code the helpers never ran.
/// Nothing is written, verified or skipped: Gatekeeper, quarantine and the code signature checks
/// run as they always do, only earlier.
public nonisolated struct StagedUpdatePrewarm: Equatable, Sendable {
    /// The argument a pre-warm starts the staged app with.
    public static let argument = "--cmux-prewarm-launch"

    /// Whether `arguments` (the process's, executable first) start a pre-warm.
    public static func isPrewarm(_ arguments: [String]) -> Bool {
        arguments.dropFirst().first == argument
    }

    /// The argument the last run starts the staged app with: Chromium's first start in that copy, for real, in a
    /// throwaway profile (`CmuxNextApp.main()` runs `CEFStagedPrewarm` on it and exits). Only a build that knows it
    /// passes it, and only to a newer staged build, which knows it too.
    public static let chromiumArgument = "--cmux-prewarm-chromium"

    /// Whether `arguments` (the process's, executable first) start Chromium's pre-warm (``chromiumArgument``).
    public static func isChromiumPrewarm(_ arguments: [String]) -> Bool {
        arguments.dropFirst().first == chromiumArgument
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
        var runs: [Run] = [], app: URL?
        if let name = Self.info(bundle)?["CFBundleExecutable"] as? String {
            let executable = bundle.appending(path: "Contents/MacOS").appending(path: name)
            if files.isExecutableFile(atPath: executable.path) {
                runs.append(Run(executable: executable, arguments: [Self.argument]))
                app = executable
            }
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
        // Last, with the framework's first load paid: the app starts Chromium in a throwaway profile with one hidden
        // page on about:blank, so the renderer, GPU and network helpers' first starts are paid here too.
        if let app { runs.append(Run(executable: app, arguments: [Self.chromiumArgument])) }
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
    /// With `marker`, a pre-warm that found the staged bundle leaves ``build`` there for that build's first
    /// launch (``consumeLaunchMarker(build:at:)``), which records itself as pre-warmed (`cmux app launch-times`).
    /// The marker write runs at ``WorkPriority/userVisible`` too, for the same reason as the scan.
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
        }
        // The framework's pages a renderer and the GPU process run, which the helpers' --version never touched
        // (``readPages(under:)``). Its own idle slot on the files lane: the best-effort one may still hold the
        // rollback keep, and nobody waits for this.
        let frameworks = bundle.appending(path: "Contents/Frameworks"), started = ContinuousClock.now
        if let pages = try? await work.run(.idle, mayBlock: .files, { Self.readPages(under: frameworks) }) {
            let part = "Frameworks read \(pages.files) files, \(pages.pages) pages \(Self.milliseconds(ContinuousClock.now - started)) ms"
            progress?("launch pre-warm of \(build): \(part)")
            parts.append(part)
        }
        if let marker {
            let build = build
            try? await work.run(.userVisible, mayBlock: .files) { Self.writeLaunchMarker(build: build, at: marker) }
        }
        return "launch pre-warm of \(build) (\(bundle.lastPathComponent)): "
            + (parts.isEmpty ? "nothing to run" : parts.joined(separator: ", ") + "; \(Self.milliseconds(ContinuousClock.now - asked)) ms in all")
    }

    /// What ``readPages(under:)`` read.
    public struct Pages: Equatable, Sendable {
        public var files = 0
        public var pages = 0
        /// The bytes read, folded together, so the compiler cannot drop the reads.
        var fold: UInt8 = 0
    }

    /// Reads one byte of each page of every regular file under `root` through a read-only mapping. Blocking.
    ///
    /// The helpers' `--version` (``runs(bundle:)``) loads the CEF framework but runs none of it: with no `--type`,
    /// `CefExecuteProcess` returns -1 at once (the exit 255 in the update log; a failed load exits 1,
    /// CEFShim/src/helper_main.mm). So the framework's code a renderer and the GPU process run, and its resources
    /// (`icudtl.dat`, the V8 snapshot, the paks), were never paged in. Run on `Contents/Frameworks` after the
    /// helpers, so the framework's code signature is already attached, each page faulted in here is resident and
    /// checked when the first launch after the update maps it (about 330 MB in NIGHTLY, 2026-11-16). The pages are
    /// file-backed and clean, so the system drops them first under memory pressure.
    public static func readPages(under root: URL) -> Pages {
        var result = Pages()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager().enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return result }
        let page = Int(getpagesize())
        for case let url as URL in walker {
            guard let values = try? url.blockingResourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true, let size = values.fileSize, size > 0 else { continue }
            let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard let base = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0), base != MAP_FAILED else { continue }
            defer { munmap(base, size) }
            for offset in stride(from: 0, to: size, by: page) {
                result.fold ^= base.load(fromByteOffset: offset, as: UInt8.self)
                result.pages += 1
            }
            result.files += 1
        }
        return result
    }

    /// Whole milliseconds of `duration`.
    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    /// `~/Library/Application Support/<bundle id>/launch-prewarm`: the build the last pre-warm ran, until
    /// that build's first launch consumes it. One line, rewritten by each pre-warm.
    public static func launchMarkerURL(bundleIdentifier: String) -> URL {
        let support = FileManager().urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager().homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return support.appending(path: bundleIdentifier, directoryHint: .isDirectory).appending(path: "launch-prewarm")
    }

    /// Leaves `build` at `marker`. Blocking. A failure leaves no marker: that launch records itself as not pre-warmed.
    static func writeLaunchMarker(build: String, at marker: URL) {
        try? FileManager.checked.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("\(build)\n".utf8).blockingWrite(to: marker, options: .atomic)
    }

    /// Whether the marker names `build` (a pre-warm ran this build before this, its first launch); it is
    /// then removed, so a relaunch of the same build is not pre-warmed. A marker of another build (a staged
    /// update not installed yet) stays. Blocking.
    public static func consumeLaunchMarker(build: String, at marker: URL) -> Bool {
        guard !build.isEmpty, let data = try? Data(blockingContentsOf: marker),
              String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == build else { return false }
        try? FileManager.checked.removeItem(at: marker)
        return true
    }

    /// ``consumeLaunchMarker(build:at:)`` at the app's own marker (``launchMarkerURL(bundleIdentifier:)``).
    public static func consumeLaunchMarker(build: String, bundleIdentifier: String) -> Bool {
        consumeLaunchMarker(build: build, at: launchMarkerURL(bundleIdentifier: bundleIdentifier))
    }

    /// A bundle's Info.plist, or nil.
    static func info(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(blockingContentsOf: bundle.appending(path: "Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
