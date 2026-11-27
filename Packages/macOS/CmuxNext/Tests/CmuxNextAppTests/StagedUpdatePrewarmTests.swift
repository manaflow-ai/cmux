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
}
