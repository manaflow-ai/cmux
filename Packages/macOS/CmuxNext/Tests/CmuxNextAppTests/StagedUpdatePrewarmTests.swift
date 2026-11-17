import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
@testable import CmuxNextUpdater
import Testing

/// A staged update's first launch is pre-warmed while the person still works (goal next-launch-instant,
/// CMUX-571): the staged bundle in Sparkle's Installation folder is found by bundle id and build, its executable
/// runs once with the pre-warm argument and the bundled cmux and cmux-tui once with --version, once per staged
/// build and only for a build newer than the running one.
@MainActor @Suite(.serialized) struct StagedUpdatePrewarmTests {
    static let bundleID = "com.cmuxterm.app.debug.staged-update-prewarm"

    /// Writes `<root>/<a>/<b>/<name>.app` with an Info.plist naming `id` and `build`, its executable, the bundled
    /// executables `bins` and the Chromium helper apps `helpers` (plus a framework that is no helper), each a script
    /// that appends its name and arguments to `<root>/ran.txt`.
    @discardableResult
    static func stage(_ root: URL, _ a: String, _ b: String, id: String = bundleID, build: String,
                      bins: [String] = StagedUpdatePrewarm.bundledExecutables,
                      helpers: [String] = ["cmux Helper (GPU)", "cmux Helper"]) throws -> URL {
        let app = root.appending(path: "\(a)/\(b)/cmux.app")
        let files = FileManager.default
        try files.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try files.createDirectory(at: app.appending(path: "Contents/Resources/bin"), withIntermediateDirectories: true)
        try files.createDirectory(at: app.appending(path: "Contents/Frameworks/Sparkle.framework"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleVersion": build, "CFBundleExecutable": "cmux"]
        try info.write(to: app.appending(path: "Contents/Info.plist"))
        let log = root.appending(path: "ran.txt").path
        let helperScripts = try helpers.map { helper in
            let folder = app.appending(path: "Contents/Frameworks/\(helper).app/Contents/MacOS")
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appending(path: helper)
        }
        for script in [app.appending(path: "Contents/MacOS/cmux")] + bins.map({ app.appending(path: "Contents/Resources/bin/\($0)") }) + helperScripts {
            let name = script.path.hasSuffix(".app/Contents/MacOS/cmux") && !script.path.contains("Helper") ? "app" : script.lastPathComponent
            try "#!/bin/sh\necho \"\(name) $*\" >> '\(log)'\n".write(to: script, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        return app
    }

    static func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "staged-update-prewarm-\(UUID().uuidString)/Installation")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func onlyThePrewarmArgumentStartsAPrewarm() {
        #expect(StagedUpdatePrewarm.isPrewarm(["/A/cmux", StagedUpdatePrewarm.argument]))
        #expect(!StagedUpdatePrewarm.isPrewarm(["/A/cmux"]))
        #expect(!StagedUpdatePrewarm.isPrewarm(["/A/cmux", "-ApplePersistenceIgnoreState", "YES"]))
        #expect(!StagedUpdatePrewarm.isPrewarm([StagedUpdatePrewarm.argument]), "the executable itself is not an argument")
    }

    @Test func theStagedBundleIsTheOneWithThisIdAndBuild() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Self.stage(root, "u1", "x1", build: "199")
        try Self.stage(root, "u2", "x2", id: "com.example.other", build: "200")
        let staged = try Self.stage(root, "u3", "x3", build: "200")
        let prewarm = StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200")
        #expect(prewarm.stagedBundle()?.standardizedFileURL == staged.standardizedFileURL)
        #expect(StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "201").stagedBundle() == nil)
        #expect(StagedUpdatePrewarm(installation: root.appending(path: "missing"), bundleIdentifier: Self.bundleID, build: "200").stagedBundle() == nil)
    }

    @Test func runsAreTheExecutableThenEachBundledExecutableThenEachHelperThatIsThere() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let full = try Self.stage(root, "u1", "x1", build: "200")
        let prewarm = StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200")
        #expect(prewarm.runs(bundle: full).map { "\($0.executable.lastPathComponent) \($0.arguments.joined(separator: " "))" }
            == ["cmux \(StagedUpdatePrewarm.argument)", "cmux --version", "cmux-tui --version",
                "cmux Helper (GPU) --version", "cmux Helper --version", "cmux \(StagedUpdatePrewarm.chromiumArgument)"])
        let bare = try Self.stage(root, "u2", "x2", build: "201", bins: [], helpers: [])
        #expect(prewarm.runs(bundle: bare).map(\.arguments) == [[StagedUpdatePrewarm.argument], [StagedUpdatePrewarm.chromiumArgument]])
    }

    /// Chromium's pre-warm runs the staged app itself, last, once the framework's first load is paid by the helpers'
    /// `--version` runs; a bundle with no executable of its own gets no Chromium run either.
    @Test func chromiumRunsLastAndOnlyWithTheAppsExecutable() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let full = try Self.stage(root, "u1", "x1", build: "200")
        let prewarm = StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200")
        let runs = prewarm.runs(bundle: full)
        #expect(runs.last?.arguments == [StagedUpdatePrewarm.chromiumArgument])
        #expect(runs.last?.executable == runs.first?.executable, "Chromium's pre-warm ran something other than the staged app")
        #expect(runs.filter { $0.arguments == [StagedUpdatePrewarm.chromiumArgument] }.count == 1)
        try FileManager.default.removeItem(at: full.appending(path: "Contents/MacOS/cmux"))
        #expect(!prewarm.runs(bundle: full).contains { $0.arguments == [StagedUpdatePrewarm.chromiumArgument] })
    }

    @Test func onlyTheChromiumArgumentStartsChromiumsPrewarm() {
        #expect(StagedUpdatePrewarm.isChromiumPrewarm(["/A/cmux", StagedUpdatePrewarm.chromiumArgument]))
        #expect(!StagedUpdatePrewarm.isChromiumPrewarm(["/A/cmux", StagedUpdatePrewarm.argument]))
        #expect(!StagedUpdatePrewarm.isPrewarm(["/A/cmux", StagedUpdatePrewarm.chromiumArgument]), "the exec-only pre-warm would skip Chromium")
        #expect(!StagedUpdatePrewarm.isChromiumPrewarm(["/A/cmux"]))
        #expect(!StagedUpdatePrewarm.isChromiumPrewarm(["/A/cmux", "--other", StagedUpdatePrewarm.chromiumArgument]), "only as the first argument")
        #expect(!StagedUpdatePrewarm.isChromiumPrewarm([StagedUpdatePrewarm.chromiumArgument]), "the executable itself is not an argument")
    }

    @Test func performRunsEachOnceWithItsArguments() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Self.stage(root, "u1", "x1", build: "200")
        let line = await StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200").perform(work: BackgroundWork())
        let ran = try String(contentsOf: root.appending(path: "ran.txt"), encoding: .utf8).split(separator: "\n")
        #expect(ran == ["app \(StagedUpdatePrewarm.argument)", "cmux --version", "cmux-tui --version",
                        "cmux Helper (GPU) --version", "cmux Helper --version", "app \(StagedUpdatePrewarm.chromiumArgument)"])
        #expect(line.hasPrefix("launch pre-warm of 200 (cmux.app): cmux exit 0"), "\(line)")
        #expect(line.contains("Frameworks read 2 files, 2 pages"), "the two helpers' executables, after they ran: \(line)")
        let none = await StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "300").perform(work: BackgroundWork())
        #expect(none.contains("no staged bundle of 300"))
    }

    /// Leo's NIGHTLY update log read "cmux exit 11" for a SIGSEGV of Chromium's pre-warm and "exit 255" for each helper
    /// that loaded the framework: a crash names its signal, and a helper's 255 says it loaded.
    @Test func aCrashNamesItsSignalAndAHelpersLoadSaysSo() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let app = try Self.stage(root, "u1", "x1", build: "200", bins: [], helpers: ["cmux Helper (GPU)"])
        let executable = app.appending(path: "Contents/MacOS/cmux")
        try "#!/bin/sh\n[ \"$1\" = \"\(StagedUpdatePrewarm.chromiumArgument)\" ] && kill -SEGV $$\nexit 0\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let helper = app.appending(path: "Contents/Frameworks/cmux Helper (GPU).app/Contents/MacOS/cmux Helper (GPU)")
        try "#!/bin/sh\nexit 255\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let line = await StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200").perform(work: BackgroundWork())
        #expect(line.contains("cmux signal 11 "), "a SIGSEGV read as an exit status: \(line)")
        #expect(line.contains("cmux Helper (GPU) exit 255 (framework loaded) "), "\(line)")
        #expect(line.contains("cmux exit 0 "), "the first run exits on its own: \(line)")
    }

    /// The helpers' --version runs none of the framework's code, so the pre-warm reads every page of every regular
    /// file under Contents/Frameworks once: empty files and symbolic links are skipped, a file one byte past three
    /// pages is four pages.
    @Test func readPagesReadsEachPageOfEachRegularFileOnce() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let page = Int(getpagesize()), files = FileManager.default
        let framework = root.appending(path: "Frameworks/Chromium Embedded Framework.framework/Resources")
        try files.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 3 * page + 1).write(to: framework.appending(path: "resources.pak"))
        try Data([1]).write(to: root.appending(path: "Frameworks/libone.dylib"))
        try Data().write(to: root.appending(path: "Frameworks/empty"))
        try files.createSymbolicLink(at: root.appending(path: "Frameworks/link.pak"), withDestinationURL: framework.appending(path: "resources.pak"))
        let pages = StagedUpdatePrewarm.readPages(under: root.appending(path: "Frameworks"))
        #expect(pages.files == 2 && pages.pages == 5, "\(pages)")
        #expect(StagedUpdatePrewarm.readPages(under: root.appending(path: "missing")) == StagedUpdatePrewarm.Pages())
    }

    /// A pre-warm that ran leaves its build for that build's first launch, which consumes it (`cmux app launch-times`'
    /// `prewarmed`); a relaunch of the same build and a launch of another build are not pre-warmed.
    @Test func aPrewarmLeavesItsBuildForItsFirstLaunchOnly() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Self.stage(root, "u1", "x1", build: "200")
        let marker = root.deletingLastPathComponent().appending(path: "support/launch-prewarm")
        _ = await StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "300").perform(work: BackgroundWork(), marker: marker)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "no staged bundle ran: no marker")
        _ = await StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200").perform(work: BackgroundWork(), marker: marker)
        #expect(!StagedUpdatePrewarm.consumeLaunchMarker(build: "199", at: marker), "another build's launch")
        #expect(StagedUpdatePrewarm.consumeLaunchMarker(build: "200", at: marker))
        #expect(!StagedUpdatePrewarm.consumeLaunchMarker(build: "200", at: marker), "a relaunch of the same build")
    }

    /// The running app is build 100.
    static func updater(stagedBuild: String?, bundleIdentifier: String = bundleID) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: bundleIdentifier, shortVersion: "1.0.0", build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = UserDefaults(testSuiteName: "StagedUpdatePrewarmTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        updater.stagedBuild = { stagedBuild }
        updater.notesLoader = { _ in nil }
        return updater
    }

    @Test func aNewerStagedBuildIsPrewarmedOnce() async {
        let updater = Self.updater(stagedBuild: "200")
        let (stream, sink) = AsyncStream<StagedUpdatePrewarm>.makeStream()
        updater.prewarmRunner = { sink.yield($0); return "pre-warmed" }
        updater.followStagedUpdate(.ready(version: "2.0.0"))
        updater.followStagedUpdate(.ready(version: "2.0.0"))
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.build == "200")
        #expect(first?.bundleIdentifier == Self.bundleID)
        #expect(first?.installation == UpdateInstallPreflight.stagedInstallation(bundleIdentifier: Self.bundleID))
        #expect(updater.prewarmedBuild == "200")
        sink.finish()
        #expect(await iterator.next() == nil, "the same staged build was pre-warmed twice")
    }

    @Test func theRunningOrAnOlderBuildIsNeverPrewarmed() {
        for build in ["100", "99", ""] {
            let updater = Self.updater(stagedBuild: build)
            updater.prewarmRunner = { _ in Issue.record("pre-warmed staged build \(build)"); return "" }
            updater.followStagedUpdate(.ready(version: "0.9.9"))
            #expect(updater.prewarmedBuild == nil)
        }
    }

    // Leo's NIGHTLY (cmux#43890's second read-back, pid 12985): "staged, waiting for the user" at 22:38:18Z, "staged
    // notes: 4376790554901" at 22:38:19Z (so the pre-warm was started with that build), "kept 4376544293601 for
    // rollback" at 22:38:45Z, the click at 22:39:16Z, and no "launch pre-warm" line at all. The pre-warm's folder
    // scan ran on the files lane's best-effort slot, behind the rollback keep the same staging starts and whatever
    // else waits there, and its only line came after its last run.

    func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        // One check per pass, and its answer is the result: a condition that takes something (a semaphore's
        // signal) answers true once, so a second check after the loop said false (#43979's first fleet run).
        let deadline = ContinuousClock.now + timeout
        while true {
            if condition() { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The real updater's staged state: Sparkle's Installation folder in the user's caches holds the staged
    /// bundle, `followStagedUpdate(.ready)` starts the pre-warm with no stand-in runner, and the files lane's
    /// best-effort slot is busy (the rollback keep: a clone of the running app, then a signature read of every
    /// kept build). The pre-warm still runs the staged bundle, and says so in the update log as it goes.
    @Test func aStagedUpdateIsPrewarmedWhileTheRollbackKeepHoldsTheFilesLane() async throws {
        let id = "\(Self.bundleID).\(UUID().uuidString.prefix(8).lowercased())"
        let installation = UpdateInstallPreflight.stagedInstallation(bundleIdentifier: id)
        let caches = installation.deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: caches) }
        try FileManager.default.createDirectory(at: installation, withIntermediateDirectories: true)
        try Self.stage(installation, "u1", "x1", id: id, build: "200")
        let updater = Self.updater(stagedBuild: "200", bundleIdentifier: id)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        // As the real keep (UpdaterService+Rollback): a best-effort task, so `run` does not boost the item to
        // this main-actor test's priority and the stand-in holds only the best-effort slot.
        let keep = Task(priority: WorkPriority.bestEffort.taskPriority) {
            try? await updater.work.run(.bestEffort, mayBlock: .files) {
                started.signal()
                _ = release.wait(timeout: .now() + 30)
            }
        }
        defer { release.signal() }
        try #require(await eventually { started.wait(timeout: .now()) == .success }, "the stand-in keep never ran")
        updater.followStagedUpdate(.ready(version: "2.0.0"))
        #expect(updater.log.recent.contains("launch pre-warm of 200: started"), "\(updater.log.recent)")
        let ran = installation.appending(path: "ran.txt")
        let firstRunLogged = await eventually { updater.log.recent.contains { $0.hasPrefix("launch pre-warm of 200: cmux exit 0") } }
        // The update log's pre-warm lines show in the failure itself (a fleet summary keeps one line per issue).
        let lines = updater.log.recent.filter { $0.contains("pre-warm") }
        #expect(firstRunLogged, "no line as the first run ended while the keep still held the files lane: \(lines)")
        #expect(lines.count >= 2, "\(lines)")
        #expect(FileManager.default.fileExists(atPath: ran.path),
                "the pre-warm waited behind the rollback keep on the files lane")
        release.signal()
        await keep.value
    }

    /// A staged update that is not pre-warmed says why in the update log, once per build.
    @Test func aSkippedPrewarmSaysWhyOnce() {
        let updater = Self.updater(stagedBuild: "99")
        updater.followStagedUpdate(.ready(version: "0.9.9"))
        updater.followStagedUpdate(.ready(version: "0.9.9"))
        let skipped = updater.log.recent.filter { $0.hasPrefix("launch pre-warm: skipped") }
        #expect(skipped == ["launch pre-warm: skipped (staged build 99 is not newer than running build 100)"], "\(updater.log.recent)")
        let none = Self.updater(stagedBuild: nil)
        none.followStagedUpdate(.ready(version: "2.0.0"))
        #expect(none.log.recent.contains("launch pre-warm: skipped (no staged build)"), "\(none.log.recent)")
    }
}
