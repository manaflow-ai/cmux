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
struct ComputerUseHelperDaemonStagingTests {
    @Test func theHelperLaunchesFromItsCopy() async throws {
        let fixture = try StagingFixture()
        defer { fixture.remove() }
        let launcher = RecordingHelperLauncher()
        let helper = fixture.daemon(launcher)
        await helper.apply(enabled: true)
        #expect(launcher.launched == [fixture.destination], "launched: \(launcher.launched)")
        #expect(helper.state == .running(321))
    }

    @Test func aCopyThatCannotBeVerifiedNeverLaunches() async throws {
        let fixture = try StagingFixture(verifies: false)
        defer { fixture.remove() }
        let launcher = RecordingHelperLauncher()
        let helper = fixture.daemon(launcher)
        await helper.apply(enabled: true)
        #expect(launcher.launched.isEmpty)
        #expect(helper.state == .unavailable)
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

    init(verifies: Bool = true) throws {
        // A short real path (no /var -> /private/var link in the way).
        root = URL(fileURLWithPath: "/private/tmp/cua-staging-\(UUID().uuidString.prefix(8))", isDirectory: true)
        source = root.appending(path: "cmux NIGHTLY.app/Contents/Library/\(Self.appName)", directoryHint: .isDirectory)
        folder = root.appending(path: "support/helper/next-0123456789abcdef", directoryHint: .isDirectory)
        let recorder = recorder
        staging = ComputerUseHelperStaging(folder: folder, operations: .init(
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
            verify: { copy, _ in verifies && FileManager.default.fileExists(atPath: copy.appending(path: "Contents/signed").path) }))
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
    func daemon(_ launcher: RecordingHelperLauncher) -> ComputerUseHelperDaemon {
        let source = source
        return ComputerUseHelperDaemon(identity: CuaHelperIdentity(isSigned: { _ in true }),
                                       candidates: { [source] },
                                       launcher: launcher,
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

    func launch(_ app: URL, arguments: [String], environment: [String: String]) async -> pid_t? {
        launched.append(app)
        return 321
    }

    func terminate(_ pid: pid_t) {}
}
