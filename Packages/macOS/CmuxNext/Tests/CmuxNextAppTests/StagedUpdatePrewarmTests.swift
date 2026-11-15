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
                "cmux Helper (GPU) --version", "cmux Helper --version"])
        let bare = try Self.stage(root, "u2", "x2", build: "201", bins: [], helpers: [])
        #expect(prewarm.runs(bundle: bare).map(\.arguments) == [[StagedUpdatePrewarm.argument]])
    }

    @Test func performRunsEachOnceWithItsArguments() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Self.stage(root, "u1", "x1", build: "200")
        let line = await StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200").perform(work: BackgroundWork())
        let ran = try String(contentsOf: root.appending(path: "ran.txt"), encoding: .utf8).split(separator: "\n")
        #expect(ran == ["app \(StagedUpdatePrewarm.argument)", "cmux --version", "cmux-tui --version",
                        "cmux Helper (GPU) --version", "cmux Helper --version"])
        #expect(line.hasPrefix("launch pre-warm of 200 (cmux.app): cmux exit 0"), "\(line)")
        let none = await StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "300").perform(work: BackgroundWork())
        #expect(none.contains("no staged bundle of 300"))
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
    static func updater(stagedBuild: String?) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: bundleID, shortVersion: "1.0.0", build: "100", minimumSystemVersion: nil,
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

    // Leo's NIGHTLY (cmux#43890's read-back): the update staged at 22:07:57Z, he clicked Restart to Update at
    // 22:08:00Z and it relaunched at 22:08:03Z with no "launch pre-warm" line: a pre-warm that only runs while
    // the update waits never finished for a person who installs at once. The click now waits for it, bounded.

    /// The harness of the install click (the feed's newest is 300, staged build 400, so the click installs
    /// what is staged) whose staged-build pre-warm runs until the returned continuation finishes.
    static func clickHarness() -> (UpdateStagedYieldsToNewerTests.Harness, UpdateClickInstallsNewestTests.Installs,
                                   AsyncStream<Void>.Continuation) {
        let (h, installs) = UpdateClickInstallsNewestTests.make(newer: false)
        let (gate, open) = AsyncStream<Void>.makeStream()
        h.updater.prewarmRunner = { _ in
            for await _ in gate {}
            return "pre-warmed"
        }
        // The harness's own staging pre-warmed build 300 (no staged bundle there); 400 is staged just now.
        h.sparkle.staged = "400"
        return (h, installs, open)
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test func aClickRightAfterStagingInstallsOnceThePrewarmEnds() async throws {
        let (h, installs, open) = Self.clickHarness()
        h.updater.followStagedUpdate(.ready(version: "4.0.0"))
        h.updater.installClicked()
        try await Task.sleep(for: .milliseconds(300))
        #expect(installs.count == 0, "the click relaunched before the pre-warm of staged build 400 ended")
        open.finish()
        #expect(await eventually { installs.count == 1 }, "the click never installed")
        #expect(h.updater.log.recent.contains { $0.hasPrefix("launch pre-warm before install: done, the install waited") },
                "\(h.updater.log.recent)")
    }

    /// A click in the same turn as the staging (no phase change seen yet) starts the pre-warm itself.
    @Test func aClickBeforeAnyPrewarmStartsOneAndWaitsForIt() async throws {
        let (h, installs, open) = Self.clickHarness()
        h.updater.installClicked()
        #expect(await eventually { h.updater.log.recent.contains("launch pre-warm of 400: started (install)") },
                "the click did not start the pre-warm: \(h.updater.log.recent)")
        try await Task.sleep(for: .milliseconds(300))
        #expect(installs.count == 0, "the click relaunched before the pre-warm it started ended")
        open.finish()
        #expect(await eventually { installs.count == 1 })
    }
}
