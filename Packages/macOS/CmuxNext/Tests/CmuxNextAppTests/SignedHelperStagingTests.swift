@testable import CmuxNextComputerUse
import CryptoKit
import Darwin
import Foundation
import Testing

/// The helper's copy lives at one fixed path per helper bundle id for every build, so macOS keeps
/// its screen-capture approval across updates (it keeps one per executable path). A new build's
/// helper replaces the copy in place under the folder's lock, which the Rust stagers
/// (`cmux_signed_bundle`) take too, and the folder of the old per-scope layout is removed.
struct SignedHelperStagingTests {
    /// Counts copies across concurrent stagers.
    actor Counter {
        var copies = 0
        func bump() { copies += 1 }
    }

    /// A scratch home whose path is its own real path (the stager compares them).
    static func home() throws -> URL {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "signed-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let real = try #require(realpath(scratch.path, nil))
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    /// A fake helper bundle at `url` whose executable holds `body`.
    static func bundle(at url: URL, body: String, version: String = "1") throws {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appending(path: "_CodeSignature"), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: contents.appending(path: "MacOS/helper"))
        try Data("seal".utf8).write(to: contents.appending(path: "_CodeSignature/CodeResources"))
        let plist: [String: Any] = ["CFBundleExecutable": "helper", "CFBundleVersion": version,
                                    "CFBundleIdentifier": "com.cmuxterm.app.test.screen-sharing"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
    }

    /// File operations over fake bundles: a stamp of the executable's bytes, a verify that
    /// `verified` decides.
    static func operations(counter: Counter? = nil, verified: Bool = true) -> SignedHelperStaging.Operations {
        SignedHelperStaging.Operations(
            copy: { source, destination in
                await counter?.bump()
                return (try? FileManager.default.copyItem(at: source, to: destination)) != nil
            },
            stamp: { bundle in
                guard let body = try? Data(contentsOf: bundle.appending(path: "Contents/MacOS/helper")) else { return nil }
                return .init(version: "1", codeDirectoryHash: body)
            },
            verify: { _, _ in verified })
    }

    static func staging(home: URL, operations: SignedHelperStaging.Operations) -> SignedHelperStaging {
        let made = SignedHelperStaging.screenSharing(bundleID: "com.cmuxterm.app.test", home: home)
        return SignedHelperStaging(folder: made.folder, home: home, root: made.root, legacy: made.legacy, operations: operations)
    }

    static func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func theCopyHasOneFixedPathPerHelperBundleID() {
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        let staging = SignedHelperStaging.screenSharing(bundleID: "com.cmuxterm.app.nightly", home: home)
        #expect(staging.folder.path == "/Users/me/Library/Application Support/cmux-next/helper/com.cmuxterm.app.nightly.screen-sharing")
        #expect(staging.root.path == "/Users/me/Library/Application Support/cmux-next/helper")
        #expect(staging.legacy?.path == "/Users/me/Library/Application Support/cmux-next/screen-sharing/73ff36dc45525a51")
        let source = URL(fileURLWithPath: "/Applications/cmux NIGHTLY.app/Contents/Library/cmux NIGHTLY Helper.app")
        #expect(staging.destination(for: source).lastPathComponent == "cmux NIGHTLY Helper.app")
    }

    @Test func everyBuildStagesToTheSamePathAndReplacesTheCopyInPlace() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let staging = Self.staging(home: home, operations: Self.operations())
        let first = home.appending(path: "v1/cmux TEST Helper.app")
        try Self.bundle(at: first, body: "one")
        let staged = try #require(await staging.stage(first))
        #expect(staged == staging.folder.appending(path: "cmux TEST Helper.app", directoryHint: .isDirectory))
        // A process of the first build keeps its executable open across the update.
        let running = try FileHandle(forReadingFrom: staged.appending(path: "Contents/MacOS/helper"))
        defer { try? running.close() }
        for body in ["two", "three"] {
            let next = home.appending(path: "\(body)/cmux TEST Helper.app")
            try Self.bundle(at: next, body: body)
            let replaced = try #require(await staging.stage(next))
            #expect(replaced == staged)
            #expect(Self.read(replaced.appending(path: "Contents/MacOS/helper")) == body)
            // The marker is the digest Rust's stager checks; nothing else is left beside the copy.
            #expect(Self.read(staging.folder.appending(path: ".verified")) == SignedHelperStaging.contentDigest(replaced))
            let names = try FileManager.default.contentsOfDirectory(atPath: staging.folder.path).sorted()
            #expect(names == [".lock", ".verified", "cmux TEST Helper.app"])
        }
        #expect(String(decoding: try running.readToEnd() ?? Data(), as: UTF8.self) == "one")
    }

    @Test func theDigestIsRustsExecutableSealAndPlistInOrder() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appending(path: "cmux TEST Helper.app")
        try Self.bundle(at: app, body: "one")
        var bytes = try Data(contentsOf: app.appending(path: "Contents/MacOS/helper"))
        bytes.append(try Data(contentsOf: app.appending(path: "Contents/_CodeSignature/CodeResources")))
        bytes.append(try Data(contentsOf: app.appending(path: "Contents/Info.plist")))
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(SignedHelperStaging.contentDigest(app) == expected)
        #expect(SignedHelperStaging.contentDigest(home.appending(path: "missing.app")) == nil)
    }

    @Test func aCopyThatFailsItsCheckNeverReplacesTheGoodOne() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let good = home.appending(path: "v1/cmux TEST Helper.app")
        try Self.bundle(at: good, body: "one")
        let staged = try #require(await Self.staging(home: home, operations: Self.operations()).stage(good))
        let next = home.appending(path: "v2/cmux TEST Helper.app")
        try Self.bundle(at: next, body: "two")
        #expect(await Self.staging(home: home, operations: Self.operations(verified: false)).stage(next) == nil)
        #expect(Self.read(staged.appending(path: "Contents/MacOS/helper")) == "one")
    }

    @Test func theOldPerScopeFolderIsRemovedAndNothingElse() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let staging = Self.staging(home: home, operations: Self.operations())
        let legacy = try #require(staging.legacy)
        try Self.bundle(at: legacy.appending(path: "cmux TEST Screen Sharing.app"), body: "old")
        try FileManager.default.createDirectory(at: legacy.appending(path: ".staging-dead"), withIntermediateDirectories: true)
        // Another scope's folder beside it (another build) is not this app's.
        let other = legacy.deletingLastPathComponent().appending(path: "0123456789abcdef")
        try Self.bundle(at: other.appending(path: "cmux OTHER Screen Sharing.app"), body: "other")
        let source = home.appending(path: "v1/cmux TEST Helper.app")
        try Self.bundle(at: source, body: "one")
        #expect(await staging.stage(source) != nil)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: other.appending(path: "cmux OTHER Screen Sharing.app").path))
        // A folder that holds anything but copies keeps it.
        try Self.bundle(at: legacy.appending(path: "cmux TEST Screen Sharing.app"), body: "old")
        try Data("keep".utf8).write(to: legacy.appending(path: "notes.txt"))
        #expect(await staging.stage(source) != nil)
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "notes.txt").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.appending(path: "cmux TEST Screen Sharing.app").path))
    }

    @Test func aStagerWaitsForTheFoldersLock() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let counter = Counter()
        let staging = Self.staging(home: home, operations: Self.operations(counter: counter))
        let source = home.appending(path: "v1/cmux TEST Helper.app")
        try Self.bundle(at: source, body: "one")
        // Another stager (the daemon, acpmux) holds the lock.
        try FileManager.default.createDirectory(at: staging.folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let held = open(staging.folder.appending(path: ".lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        #expect(held >= 0)
        #expect(flock(held, LOCK_EX) == 0)
        let staged = Task { await staging.stage(source) }
        // wakeup-allow: gives the waiting stager time to (wrongly) copy while the lock is held.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await counter.copies == 0)
        flock(held, LOCK_UN)
        close(held)
        #expect(await staged.value != nil)
        #expect(await counter.copies == 1)
    }
}
