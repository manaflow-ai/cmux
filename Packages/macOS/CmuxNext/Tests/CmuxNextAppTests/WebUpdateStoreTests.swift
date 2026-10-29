import CmuxNextWakeups
import CryptoKit
import Foundation
@testable import CmuxNextUpdater
import Testing

/// The kept web updates (plans/cmux-next/web-ota.md): the tree digest is web-bundle-key.py's
/// `--outputs`, so a tree is checked against its signed pointer again at launch; an install takes
/// only an archive whose bytes and unpacked tree match the pointer.
@Suite(.serialized) struct WebUpdateStoreTests {
    static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "WebUpdateStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The fixture tree whose `--outputs` digest web-bundle-key.py prints as ``treeDigest``:
    /// upper case sorts before lower case, `.DS_Store` is ignored, a folder's files come before
    /// its subfolders, a missing output and an empty one each count.
    static let files: [String: String] = [
        "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.html": "pane\n",
        "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/assets/a.js": "a\n",
        "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/Z.js": "z\n",
        "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/.DS_Store": "x",
        "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/web-abi.json": "{\"abi\": 2}\n",
        "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/settings/index.html": "s\n",
        "Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js": "r\n",
        "Native/OptChat/optchat-chief/inspector/index.html": "i\n",
    ]
    static let treeDigest = "645e75a54a960ed3afb77b27adf24ceea07e735eaa2cee5920eab8bfdeb9adb7"

    static func makeTree(at root: URL) throws {
        for (rel, text) in files {
            let file = root.appending(path: rel)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity"),
            withIntermediateDirectories: true)
    }

    /// A gzip tar of the fixture tree and the pointer that names it.
    static func makeArchive(in root: URL, committedAt: Int = 1_760_000_000) async throws -> (URL, WebUpdatePointer) {
        let tree = root.appending(path: "src", directoryHint: .isDirectory)
        try makeTree(at: tree)
        let archive = root.appending(path: "a.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["--no-mac-metadata", "-czf", archive.path, "-C", tree.path, "Packages", "Native"]
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
        #expect(status == 0)
        let (size, sha) = try WebUpdateStore.sizeAndDigest(of: archive)
        let pointer = WebUpdatePointer(channel: "every-merge", key: String(repeating: "d", count: 64), archive: "web-bundles-\(sha).tar.gz",
                                       sha256: sha, size: size, outputs: treeDigest, abi: 2, commit: String(repeating: "1", count: 40),
                                       committedAt: committedAt, publishedAt: committedAt + 60)
        return (archive, pointer)
    }

    @Test func theTreeDigestIsTheScriptsOutputsDigest() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeTree(at: root)
        let tree = WebUpdateTree(root: root)
        #expect(try tree.outputDigest() == Self.treeDigest)
        #expect(tree.abi == 2)
    }

    /// scripts/cmux-next/web-bundle-key.py run on the tree at `root` in `mode` (`--outputs`, `--shared`).
    static func bundleKey(_ root: URL, _ mode: String) async throws -> ProcessOutcome {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../../scripts/cmux-next/web-bundle-key.py").standardizedFileURL
        return try await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/env"), ["python3", script.path, root.path, mode],
                                                           errorOutput: .separate, timeout: .seconds(60)))
    }

    /// The script and the app hash the same outputs: a list that differs on either side (a missing
    /// output counts) gives another digest of the same tree.
    @Test func theOutputsAreTheScriptsOutputs() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeTree(at: root)
        let outcome = try await Self.bundleKey(root, "--outputs")
        #expect(outcome.succeeded, "web-bundle-key.py --outputs: \(String(decoding: outcome.errorOutput, as: UTF8.self))")
        #expect(outcome.text.trimmingCharacters(in: .whitespacesAndNewlines) == (try WebUpdateTree(root: root).outputDigest()))
    }

    @Test func aLinkInTheTreeIsRefused() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeTree(at: root)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/escape"),
            withDestinationURL: URL(fileURLWithPath: "/etc"))
        #expect(throws: WebUpdateRefusal.integrity("link escape")) { try WebUpdateTree(root: root).outputDigest() }
    }

    @Test func anInstallKeepsAMatchingArchiveAndItVerifiesAgain() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (archive, pointer) = try await Self.makeArchive(in: root)
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        let tree = try await store.install(archive: archive, pointer: pointer)
        #expect(tree == store.tree(for: pointer.key).root)
        #expect(store.verifiedTree(pointer) == tree)
        // A file changed on disk after the install: the launch check no longer serves the tree.
        try Data("evil\n".utf8).write(to: tree.appending(path: "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/settings/index.html"))
        #expect(store.verifiedTree(pointer) == nil)
    }

    @Test func anArchiveThatDoesNotMatchThePointerIsNotKept() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (archive, pointer) = try await Self.makeArchive(in: root)
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        var wrongBytes = pointer
        wrongBytes.sha256 = String(repeating: "e", count: 64)
        await #expect(throws: WebUpdateRefusal.integrity("archive digest")) { try await store.install(archive: archive, pointer: wrongBytes) }
        var wrongTree = pointer
        wrongTree.outputs = String(repeating: "f", count: 64)
        await #expect(throws: WebUpdateRefusal.integrity("tree digest")) { try await store.install(archive: archive, pointer: wrongTree) }
        #expect(!FileManager.default.fileExists(atPath: store.tree(for: pointer.key).root.path))
    }

    @Test func theLaunchCheckForgetsAnUpdateOlderThanTheBundledWeb() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (archive, pointer) = try await Self.makeArchive(in: root)
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        let tree = try await store.install(archive: archive, pointer: pointer)
        try store.write(WebUpdateState(active: pointer, floor: pointer.committedAt))
        let (kept, _) = await WebUpdater.launchCheck(store: store, app: .init(abi: 2, webBuiltAt: pointer.committedAt - 1))
        #expect(kept == tree)
        // A newer app (its web built after the update's commit) serves its own web.
        let (newer, state) = await WebUpdater.launchCheck(store: store, app: .init(abi: 2, webBuiltAt: pointer.committedAt + 1))
        #expect(newer == nil)
        #expect(state.active == nil)
        #expect(store.readState().floor == pointer.committedAt)
        #expect(!FileManager.default.fileExists(atPath: tree.path))
    }

    /// The kept update read on a launch lane before the channel is known decides
    /// as the launch check that reads the disk itself: the same tree for a kept update newer than
    /// the bundled web, and for a bundle with newer web no tree, then the bundled web served and
    /// the kept update forgotten.
    @Test func theLaunchReadOfTheKeptUpdateMatchesTheLaunchCheck() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (archive, pointer) = try await Self.makeArchive(in: root)
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        let tree = try await store.install(archive: archive, pointer: pointer)
        try store.write(WebUpdateState(active: pointer, floor: pointer.committedAt))
        let older = WebUpdater.App(abi: 2, webBuiltAt: pointer.committedAt - 1)
        let kept = WebUpdater.readKept(store: store, app: older)
        #expect(kept.tree == tree)
        #expect(kept.state.active == pointer)
        let (fromRead, readState) = await WebUpdater.launchCheck(kept, store: store, channel: .everyMerge)
        let (fromDisk, diskState) = await WebUpdater.launchCheck(store: store, app: older, channel: .everyMerge)
        #expect(fromRead == tree)
        #expect(fromRead == fromDisk)
        #expect(readState == diskState)

        // A bundle whose web is newer than the kept update: the read finds no tree to serve.
        let newer = WebUpdater.App(abi: 2, webBuiltAt: pointer.committedAt + 1)
        let stale = WebUpdater.readKept(store: store, app: newer)
        #expect(stale.tree == nil)
        #expect(stale.state.active == pointer)
        let (served, state) = await WebUpdater.launchCheck(stale, store: store, channel: .everyMerge)
        #expect(served == nil)
        #expect(state.active == nil)
        #expect(store.readState().active == nil)
        #expect(store.readState().floor == pointer.committedAt)
        #expect(!FileManager.default.fileExists(atPath: tree.path))
    }

    /// NIGHTLY updates by Sparkle delta, which rewrites only the files whose bytes changed:
    /// `web-abi.json` keeps the time of the first install across every later nightly, while each
    /// nightly rewrites `Info.plist` (its build number and commit). The bundled web's build time
    /// is the plist's, so a newer nightly still drops an older kept update.
    @Test func theBundledWebIsAsNewAsTheAppsInfoPlistNotItsWebAbiJson() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = root.appending(path: "pages", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        let abi = pages.appending(path: "web-abi.json")
        try Data("{\"abi\": 2}\n".utf8).write(to: abi)
        let plist = root.appending(path: "Info.plist")
        try Data("<plist/>\n".utf8).write(to: plist)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: abi.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_760_000_000)], ofItemAtPath: plist.path)
        let app = try #require(WebUpdater.App.bundled(pages: pages, infoPlist: plist))
        #expect(app.abi == 2)
        #expect(app.webBuiltAt == 1_760_000_000)
    }
}
