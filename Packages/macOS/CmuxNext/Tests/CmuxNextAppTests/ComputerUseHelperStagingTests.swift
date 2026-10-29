import CmuxNextAgentActivity
@testable import CmuxNextComputerUse
import Darwin
import Foundation
import Testing

/// macOS 26 checks Screen Recording for a helper nested in an app bundle as
/// the outer app (cmux NIGHTLY), so the person's "cmux Computer Use" switch
/// never applied. The helper must run from a verified copy outside any app.
struct ComputerUseHelperStagingTests {
    @Test func aMissingCopyIsMadeOutsideTheApp() async throws {
        let fixture = try StagingFixture()
        defer { fixture.remove() }
        let staged = try #require(await fixture.staging.stage(fixture.source))
        #expect(staged == fixture.folder.appending(path: StagingFixture.appName, directoryHint: .isDirectory))
        #expect(!staged.path.contains(".app/"), "the copy must not be inside another app: \(staged.path)")
        #expect(ComputerUseHelperStaging.isRealDirectory(staged.path))
        #expect(fixture.recorder.copies == 1)
        #expect(try fixture.hash(of: staged) == "v1")
        #expect(fixture.leftovers().isEmpty)
    }

    @Test func aMatchingCopyIsReused() async throws {
        let fixture = try StagingFixture()
        defer { fixture.remove() }
        let first = try #require(await fixture.staging.stage(fixture.source))
        let inode = try fixture.inode(first)
        let second = try #require(await fixture.staging.stage(fixture.source))
        #expect(second == first)
        #expect(fixture.recorder.copies == 1, "a copy of the same helper is not copied again")
        #expect(try fixture.inode(second) == inode)
    }

    @Test func aChangedSourceReplacesTheCopy() async throws {
        let fixture = try StagingFixture()
        defer { fixture.remove() }
        let first = try #require(await fixture.staging.stage(fixture.source))
        try fixture.writeBundle(at: fixture.source, version: "2", hash: "v2")
        let second = try #require(await fixture.staging.stage(fixture.source))
        #expect(second == first)
        #expect(fixture.recorder.copies == 2)
        #expect(try fixture.hash(of: second) == "v2")
        #expect(fixture.leftovers().isEmpty, "the old copy and the staging folder are removed")
    }

    @Test func aCopyThatFailsTheSignatureCheckIsRefused() async throws {
        let fixture = try StagingFixture(verifies: false)
        defer { fixture.remove() }
        #expect(await fixture.staging.stage(fixture.source) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(fixture.leftovers().isEmpty)
    }

    @Test func aTamperedCopyIsReplaced() async throws {
        let fixture = try StagingFixture()
        defer { fixture.remove() }
        let first = try #require(await fixture.staging.stage(fixture.source))
        try FileManager.default.removeItem(at: first.appending(path: "Contents/signed"))
        let second = try #require(await fixture.staging.stage(fixture.source))
        #expect(fixture.recorder.copies == 2)
        #expect(FileManager.default.fileExists(atPath: second.appending(path: "Contents/signed").path))
    }

    @Test func aSymlinkAtTheCopyIsReplacedNotFollowed() async throws {
        let fixture = try StagingFixture()
        defer { fixture.remove() }
        // A valid-looking helper elsewhere, linked in where the copy goes.
        let elsewhere = fixture.root.appending(path: "elsewhere/\(StagingFixture.appName)", directoryHint: .isDirectory)
        try fixture.writeBundle(at: elsewhere, version: "1", hash: "v1")
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: elsewhere)
        let staged = try #require(await fixture.staging.stage(fixture.source))
        #expect(ComputerUseHelperStaging.isRealDirectory(staged.path), "the launched copy is never a symlink")
        #expect(fixture.recorder.copies == 1)
        #expect(FileManager.default.fileExists(atPath: elsewhere.appending(path: "Contents/Info.plist").path),
                "the link's target is left alone")
    }

    @Test func aSymlinkedFolderIsRefused() async throws {
        let fixture = try StagingFixture()
        defer { fixture.remove() }
        let elsewhere = fixture.root.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.folder, withDestinationURL: elsewhere)
        #expect(await fixture.staging.stage(fixture.source) == nil)
        #expect(fixture.recorder.copies == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test func aSymlinkedAncestorIsRefused() async throws {
        let fixture = try StagingFixture()
        defer { fixture.remove() }
        let support = fixture.root.appending(path: "Library/Application Support")
        let elsewhere = fixture.root.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: support.appending(path: "cmux"), withDestinationURL: elsewhere)
        #expect(await fixture.staging.stage(fixture.source) == nil)
        #expect(await fixture.staging.existingCopy(named: StagingFixture.appName) == nil)
        #expect(fixture.recorder.copies == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test func aWritableAncestorIsRefused() async throws {
        let fixture = try StagingFixture()
        defer { fixture.remove() }
        let cmux = fixture.root.appending(path: "Library/Application Support/cmux")
        try FileManager.default.createDirectory(at: cmux, withIntermediateDirectories: true)
        try #require(chmod(cmux.path, 0o770) == 0)
        #expect(await fixture.staging.stage(fixture.source) == nil)
        #expect(fixture.recorder.copies == 0)
    }

    @Test func aForeignAncestorIsRefused() async throws {
        let fixture = try StagingFixture(fileSystem: .init(inspect: { url in
            guard var entry = ComputerUseHelperStaging.FileSystem.Entry.read(url) else { return nil }
            if url.lastPathComponent == "cmux" { entry.owner = geteuid() + 1 }
            return entry
        }))
        defer { fixture.remove() }
        #expect(await fixture.staging.stage(fixture.source) == nil)
        #expect(fixture.recorder.copies == 0)
    }

    @Test(arguments: ["matching", "version", "hash", "signature"])
    func aConcurrentWinnerIsUsedOnlyWhenVerified(_ kind: String) async throws {
        let fixture = try StagingFixture(fileSystem: .init(move: { source, destination, _ in
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                if kind == "version" {
                    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "wrong"], format: .xml, options: 0)
                    try plist.write(to: destination.appending(path: "Contents/Info.plist"))
                } else if kind == "hash" {
                    try Data("wrong".utf8).write(to: destination.appending(path: "Contents/hash"))
                } else if kind == "signature" {
                    try FileManager.default.removeItem(at: destination.appending(path: "Contents/signed"))
                }
                return EEXIST
            } catch { return EIO }
        }))
        defer { fixture.remove() }
        let staged = await fixture.staging.stage(fixture.source)
        #expect(staged == (kind == "matching" ? fixture.destination : nil))
        #expect(fixture.leftovers().isEmpty)
    }

    @Test func oldStagingDirectoriesAreSweptButRecentOnesAndLinksRemain() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try StagingFixture(fileSystem: .init(now: { now }, inspect: { url in
            guard var entry = ComputerUseHelperStaging.FileSystem.Entry.read(url) else { return nil }
            if url.lastPathComponent == ".staging-foreign" { entry.owner = geteuid() + 1 }
            return entry
        }))
        defer { fixture.remove() }
        _ = try #require(await fixture.staging.stage(fixture.source))
        let old = fixture.folder.appending(path: ".staging-old")
        let recent = fixture.folder.appending(path: ".staging-recent")
        let unrelated = fixture.folder.appending(path: "unrelated")
        let link = fixture.folder.appending(path: ".staging-link")
        let foreign = fixture.folder.appending(path: ".staging-foreign")
        for directory in [old, recent, unrelated, foreign] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(directory == recent ? -60 : -600)],
                                                 ofItemAtPath: directory.path)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        _ = try #require(await fixture.staging.stage(fixture.source))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: link.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test func theSetupTileNamesOnlyAVerifiedCopy() async throws {
        let fixture = try StagingFixture()
        defer { fixture.remove() }
        #expect(await fixture.staging.existingCopy(named: StagingFixture.appName) == nil)
        let staged = try #require(await fixture.staging.stage(fixture.source))
        #expect(await fixture.staging.existingCopy(named: StagingFixture.appName) == staged)
    }

    @Test func theDefaultCopiesLiveOutsideAnyAppPerBuild() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let legacy = ComputerUseHelperStaging.legacy(bundleID: "com.cmuxterm.app.nightly", home: home)
        let upstream = ComputerUseHelperStaging.upstream(bundleID: "com.cmuxterm.app.nightly", home: home)
        let scope = ComputerUseHelperDaemon.scope("com.cmuxterm.app.nightly")
        #expect(legacy.folder.path == "/Users/someone/Library/Application Support/cmux/cmux-cua/helper/next-\(scope)")
        #expect(upstream.folder.path == "/Users/someone/Library/Application Support/cmux/cmux-cua/helper/next-v2-\(scope)")
        #expect(!legacy.folder.path.contains(".app"))
    }
}

@MainActor
struct ComputerUseHelperStagingTestsLaunch {
    @Test func theHelperLaunchesFromItsCopy() async throws {
        let fixture = try StagingFixture()
        defer { fixture.remove() }
        let launcher = RecordingHelperLauncher()
        let helper = fixture.daemon(launcher)
        launcher.onLaunch = { try fixture.writeBundle(at: fixture.source, version: "2", hash: "v2") }
        await helper.apply(enabled: true)
        #expect(try fixture.hash(of: fixture.source) == "v2", "the source changed after the requirement was captured")
        #expect(launcher.launched == [fixture.destination], "launched: \(launcher.launched)")
        #expect(helper.state == .running(321))
    }

    @Test func aSwappedRunningHelperIsStoppedAndItsTokenReplaced() async throws {
        let fixture = try StagingFixture(runningVerifies: false)
        defer { fixture.remove() }
        let launcher = RecordingHelperLauncher()
        let helper = fixture.daemon(launcher)
        var pushed: [[String: String]] = []
        helper.onEndpointChange = { pushed.append($0) }
        let published = helper.childEnvironment["CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"]
        await helper.apply(enabled: true)
        #expect(launcher.launched == [fixture.destination])
        #expect(launcher.terminated == [321])
        #expect(helper.state == .failed, "a check failure is not \"no signed helper\": Restart Helper applies")
        #expect(helper.configuration == nil)
        // The endpoint stays published from launch (ComputerUseEndpointTests),
        // but the agent token the swapped process got is no longer served.
        let leaked = try #require(launcher.environments.first?["CMUX_CUA_SOCKET_AUTH_TOKEN"])
        #expect(leaked == published)
        let current = try #require(helper.childEnvironment["CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"])
        #expect(current != leaked, "chats that start later get a new agent token")
        // The running acpmux gets the new token now, not when a pane reconnects.
        #expect(pushed == [helper.childEnvironment], "pushed: \(pushed.map { $0.keys.sorted() })")
    }

    @Test func aSwappedV2HelperGetsNoConfigurationOrEndpoint() async throws {
        let fixture = try StagingFixture(runningVerifies: false)
        defer { fixture.remove() }
        let input = fixture.root.appending(path: "control")
        let descriptor = open(input.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        try #require(descriptor >= 0)
        let directory = fixture.root.appending(path: "v2").path
        let child = ComputerUseHelperV2Child(pid: 321, input: descriptor,
            lines: AsyncStream { continuation in
                continuation.yield(ComputerUseHelperV2.line(["type": "ready", "socket": directory + "/h.sock"]))
                continuation.finish()
            })
        defer { child.closeInput() }
        let spawner = StagingV2Spawner(child: child)
        let source = fixture.source
        let helper = ComputerUseHelperV2(directory: directory, helperApp: { source },
                                         staging: fixture.staging, spawner: spawner)
        await helper.apply(enabled: true)
        #expect(spawner.terminated == [321])
        #expect(try Data(contentsOf: input).isEmpty, "no secret or command may reach the untrusted pid")
        #expect(!FileManager.default.fileExists(atPath: helper.endpointPath))
        guard case .unavailable = helper.state else {
            Issue.record("the untrusted helper must be unavailable")
            helper.terminateForQuit()
            return
        }
    }

    @Test func aCopyThatCannotBeVerifiedNeverLaunches() async throws {
        let fixture = try StagingFixture(verifies: false)
        defer { fixture.remove() }
        let launcher = RecordingHelperLauncher()
        let helper = fixture.daemon(launcher)
        await helper.apply(enabled: true)
        #expect(launcher.launched.isEmpty)
        #expect(helper.state == .failed)
    }

    /// `.unavailable` tells the agent "no signed helper in this build; do not
    /// call computer use tools". Only a missing helper means that. A copy,
    /// lock, launch or check failure is `.failed`: the setup offers Restart
    /// Helper and the agent's call is not refused for the build.
    @Test func onlyAMissingSignedHelperIsUnavailable() async throws {
        let fixture = try StagingFixture()
        defer { fixture.remove() }
        let launcher = RecordingHelperLauncher()
        let unsigned = fixture.daemon(launcher, signed: false)
        await unsigned.apply(enabled: true)
        #expect(unsigned.state == .unavailable)
        #expect(launcher.launched.isEmpty)

        // The launcher took no pid: the scope lock is held, or LaunchServices failed.
        launcher.pid = nil
        let notLaunched = fixture.daemon(launcher)
        await notLaunched.apply(enabled: true)
        #expect(launcher.launched == [fixture.destination])
        #expect(notLaunched.state == .failed)
    }

    /// An older helper exits at launch on a flag it does not know, so the
    /// cursor motion flags go only to a helper whose manifest lists
    /// `serve.motion`, as `--owner-pid` goes only with `serve.owner-pid`.
    @Test(arguments: [false, true])
    func theMotionFlagsGoOnlyToAHelperThatListsThem(_ listed: Bool) async throws {
        let fixture = try StagingFixture()
        defer { fixture.remove() }
        let capabilities = listed ? #"["serve.owner-pid","serve.motion"]"# : #"["serve.owner-pid"]"#
        try fixture.writeManifest(#"{"binary_version":"0.8.11","capabilities":\#(capabilities)}"#)
        let launcher = RecordingHelperLauncher()
        let helper = fixture.daemon(launcher, manifestReader: CuaHelperManifestReader())
        await helper.apply(enabled: true)
        let argv = try #require(launcher.arguments.first)
        #expect(argv.contains("--owner-pid"), "the manifest was not read: \(argv)")
        #expect(argv.contains("--glide-ms") == listed, "\(argv)")
        #expect(argv.contains("--dwell-ms") == listed, "\(argv)")
    }

    /// `~/Library/Application Support/cmux` made under umask 002 is 0775. The
    /// group is the person's primary group, `staff` on macOS, which holds every
    /// local user, so another user could swap the copy: it stays refused, but
    /// as a failure with Restart Helper, not as a build without a helper.
    @Test func aGroupWritableAncestorIsAFailureNotAMissingHelper() async throws {
        let fixture = try StagingFixture()
        defer { fixture.remove() }
        let shared = fixture.root.appending(path: "Library/Application Support/cmux", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        #expect(chmod(shared.path, 0o775) == 0)
        let launcher = RecordingHelperLauncher()
        let helper = fixture.daemon(launcher)
        await helper.apply(enabled: true)
        #expect(launcher.launched.isEmpty)
        #expect(helper.state == .failed)
    }
}

/// A fake helper bundle and a staging with file and signature fakes: the
/// stamp is the bundle's version plus `Contents/hash`, and a copy passes its
/// check when `Contents/signed` is there (and the fixture verifies at all).
private struct StagingFixture {
    static let appName = "cmux Computer Use.app"
    let root: URL
    let source: URL
    let folder: URL
    let recorder = CopyRecorder()
    let staging: ComputerUseHelperStaging
    var destination: URL { folder.appending(path: Self.appName, directoryHint: .isDirectory) }

    init(verifies: Bool = true, runningVerifies: Bool = true, fileSystem: ComputerUseHelperStaging.FileSystem = .init()) throws {
        // A short real path (no /var -> /private/var link in the way).
        root = URL(fileURLWithPath: "/private/tmp/cua-staging-\(UUID().uuidString.prefix(8))", isDirectory: true)
        source = root.appending(path: "cmux NIGHTLY.app/Contents/Library/\(Self.appName)", directoryHint: .isDirectory)
        folder = root.appending(path: "Library/Application Support/cmux/cmux-cua/helper/next-0123456789abcdef", directoryHint: .isDirectory)
        let recorder = recorder
        staging = ComputerUseHelperStaging(folder: folder, home: root, operations: .init(
            copy: { source, destination in
                recorder.recordCopy()
                return (try? FileManager.default.copyItem(at: source, to: destination)) != nil
            },
            stamp: { bundle in
                guard let data = try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist")),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                      let version = plist["CFBundleVersion"] as? String,
                      let hash = try? Data(contentsOf: bundle.appending(path: "Contents/hash")) else { return nil }
                return .init(version: version, codeDirectoryHash: hash)
            },
            verify: { copy, _ in verifies && FileManager.default.fileExists(atPath: copy.appending(path: "Contents/signed").path) },
            makeRunningCheck: { source in
                let hash = try? Data(contentsOf: source.appending(path: "Contents/hash"))
                return { pid in
                    #expect(!Thread.isMainThread)
                    #expect(pid == 321)
                    return runningVerifies && hash == Data("v1".utf8)
                }
            }), fileSystem: fileSystem)
        try writeBundle(at: source, version: "1", hash: "v1")
    }

    func writeBundle(at bundle: URL, version: String, hash: String) throws {
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": version], format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        try Data(hash.utf8).write(to: contents.appending(path: "hash"))
        try Data().write(to: contents.appending(path: "signed"))
        try Data("#!/bin/sh\n".utf8).write(to: contents.appending(path: "MacOS/cmux-cua"))
    }

    /// Makes the source helper's executable answer `manifest` with `json`.
    func writeManifest(_ json: String) throws {
        let executable = source.appending(path: "Contents/MacOS/cmux-cua")
        try Data("#!/bin/sh\nprintf '%s' '\(json)'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func hash(of bundle: URL) throws -> String {
        String(decoding: try Data(contentsOf: bundle.appending(path: "Contents/hash")), as: UTF8.self)
    }

    func inode(_ url: URL) throws -> UInt64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileNoSuchFile) }
        return UInt64(info.st_ino)
    }

    /// Anything in the folder besides the copy (staging folders, old copies).
    func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != Self.appName }
    }

    @MainActor
    func daemon(_ launcher: RecordingHelperLauncher, signed: Bool = true,
                manifestReader: CuaHelperManifestReader = .shared) -> ComputerUseHelperDaemon {
        let source = source
        return ComputerUseHelperDaemon(identity: CuaHelperIdentity(isSigned: { _ in signed }),
                                       candidates: { [source] },
                                       launcher: launcher,
                                       manifestReader: manifestReader,
                                       staging: staging,
                                       socketPath: root.appending(path: "s/cua.sock").path,
                                       stateDirectory: root.appending(path: "state"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private nonisolated final class CopyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var copies: Int { lock.withLock { count } }
    func recordCopy() { lock.withLock { count += 1 } }
}

@MainActor
private final class RecordingHelperLauncher: ComputerUseHelperLaunching {
    var launched: [URL] = []
    var arguments: [[String]] = []
    var environments: [[String: String]] = []
    var terminated: [pid_t] = []
    var onLaunch: (() throws -> Void)?
    /// What a launch returns; nil as when the scope lock is held or LaunchServices fails.
    var pid: pid_t? = 321

    func launch(_ app: URL, arguments: [String], environment: [String: String]) async -> pid_t? {
        launched.append(app)
        self.arguments.append(arguments)
        environments.append(environment)
        do { try onLaunch?() } catch { Issue.record(error) }
        return pid
    }

    func terminate(_ pid: pid_t) { terminated.append(pid) }

    func isRunning(_ pid: pid_t) -> Bool { true }

    func watchExit(of pid: pid_t, onExit: @escaping @MainActor () -> Void) -> @MainActor () -> Void { {} }
}

// The lock protects the synchronous spawner callback used by the test.
private nonisolated final class StagingV2Spawner: ComputerUseHelperV2Spawning, @unchecked Sendable {
    let child: ComputerUseHelperV2Child
    private let lock = NSLock()
    private var pids: [pid_t] = []
    var terminated: [pid_t] { lock.withLock { pids } }
    init(child: ComputerUseHelperV2Child) { self.child = child }
    func spawn(executable: URL, environment: [String: String], logPath: String) throws -> ComputerUseHelperV2Child { child }
    func terminate(_ pid: pid_t) { lock.withLock { pids.append(pid) } }
    @MainActor func watchExit(of pid: pid_t, onExit: @escaping @MainActor () -> Void) -> @MainActor () -> Void { {} }
}
