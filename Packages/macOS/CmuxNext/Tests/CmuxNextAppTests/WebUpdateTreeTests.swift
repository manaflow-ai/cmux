import CmuxNextPages
import Foundation
@testable import CmuxNextUpdater
import Testing

/// One React for every web tree: the pages, the webviews app and Agent Activity import it
/// from `cmux-page://cmux.shared/`, the tree's own `pages/_shared`. A tree, and so a web update, holds every
/// shared file its bundles name (web-bundle-key.py `--shared`); an install refuses one that does not.
@Suite(.serialized) struct WebUpdateTreeTests {
    static let pages = "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
    static let app = "Resources/markdown-viewer/webviews-app"
    static let activity = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity"
    static let react = "react-AB12CD34.js"

    /// A built tree: every page, viewer and Activity screen imports the one React in `pages/_shared`.
    static let files: [String: String] = [
        "\(pages)/web-abi.json": "{\"abi\": 2}\n",
        "\(pages)/_shared/\(react)": "export const react$useState = 1;\n",
        "\(pages)/_shared/chunk-A.js": "import{react$useState as u}from\"cmux-page://cmux.shared/\(react)\";export const a=u;\n",
        "\(pages)/settings/index.html":
            "<link rel=\"modulepreload\" href=\"cmux-page://cmux.shared/\(react)\" /><script type=\"module\" src=\"app-H.js\"></script>\n",
        "\(app)/chunks/vendor.mjs": "import{react$default as R}from\"cmux-page://cmux.shared/\(react)\";export{R};\n",
        "\(app)/diff-page.html": "<script type=\"module\" src=\"./chunks/diff-page.mjs\"></script>\n",
        "\(activity)/index.html":
            "<meta http-equiv=\"Content-Security-Policy\" content=\"script-src 'unsafe-inline' cmux-page://cmux.shared; style-src 'unsafe-inline'\" />"
            + "<script type=\"module\">import{react_dom_client$createRoot as c}from\"cmux-page://cmux.shared/\(react)\";</script>\n",
    ]

    static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "WebUpdateTreeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func write(_ files: [String: String], at root: URL) throws {
        for (rel, text) in files {
            let file = root.appending(path: rel)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
    }

    @Test func aBuiltTreeHoldsEverySharedFileItsBundlesName() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(Self.files, at: root)
        #expect(try WebUpdateTree(root: root).missingSharedFiles() == [])
    }

    @Test func aViewerOrActivityThatNamesAFileTheTreeLacksIsFound() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        var files = Self.files
        // A webviews app and an Activity screen built against another React than the pages'.
        files["\(Self.app)/chunks/vendor.mjs"] = "import{react$default as R}from\"cmux-page://cmux.shared/react-OTHER1.js\";\n"
        files["\(Self.activity)/index.html"] = "<link rel=\"modulepreload\" href=\"cmux-page://cmux.shared/react-OTHER2.js\" />\n"
        try Self.write(files, at: root)
        #expect(try WebUpdateTree(root: root).missingSharedFiles() == ["react-OTHER1.js", "react-OTHER2.js"])
    }

    @Test func aSharedNameOutsideTheSharedFolderIsNeverHeld() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        var files = Self.files
        files["\(Self.app)/chunks/escape.mjs"] =
            "import\"cmux-page://cmux.shared/../settings/index.js\";import\"cmux-page://cmux.shared/./\(Self.react)\";\n"
        files["\(Self.pages)/settings/index.js"] = "x\n"
        try Self.write(files, at: root)
        #expect(try WebUpdateTree(root: root).missingSharedFiles() == ["../settings/index.js", "./\(Self.react)"])
    }

    /// The same reading as web-bundle-key.py's SHARED_URL: the longest run of name bytes, counted only
    /// for a `.js` or `.css` name; a policy's bare origin names nothing.
    @Test func sharedNamesAreReadAsTheScriptReadsThem() {
        let text = "a cmux-page://cmux.shared; b \"cmux-page://cmux.shared/ui-1.css\" c cmux-page://cmux.shared/react-X.js\" "
            + "d cmux-page://cmux.shared/react-X.js.map e cmux-page://cmux.shared/deep/k.mjs f cmux-page://cmux.shared/"
        #expect(WebUpdateTree.sharedNames(in: Data(text.utf8)) == ["ui-1.css", "react-X.js"])
    }

    @Test func theSharedRootIsTheScriptsSharedRoot() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../../scripts/cmux-next/web-bundle-key.py").standardizedFileURL
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("SHARED_ROOT = \"\(WebUpdateTree.sharedRoot)\""))
        #expect(WebUpdateTree.sharedRoot == WebUpdateTree.outputs[1] + "/_shared")
        // The overlay maps the pages (and so their _shared) and Agent Activity by these outputs.
        #expect(WebBundleOverlay.pagesOutput == WebUpdateTree.outputs[1])
        #expect(WebBundleOverlay.agentActivityOutput == WebUpdateTree.outputs[2])
    }

    @Test func anInstallRefusesAnUpdateThatNamesASharedFileItLacks() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "src", directoryHint: .isDirectory)
        var files = Self.files
        files.removeValue(forKey: "\(Self.pages)/_shared/\(Self.react)")
        try Self.write(files, at: source)
        let archive = root.appending(path: "a.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["--no-mac-metadata", "-czf", archive.path, "-C", source.path, "Packages", "Resources"]
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
        #expect(status == 0)
        let (size, sha) = try WebUpdateStore.sizeAndDigest(of: archive)
        let outputs = try WebUpdateTree(root: source).outputDigest()
        let pointer = WebUpdatePointer(channel: "every-merge", key: String(repeating: "d", count: 64), archive: "web-bundles-\(sha).tar.gz",
                                       sha256: sha, size: size, outputs: outputs, abi: 2,
                                       commit: String(repeating: "1", count: 40), committedAt: 1_760_000_000, publishedAt: 1_760_000_060)
        let store = WebUpdateStore(base: root.appending(path: "store", directoryHint: .isDirectory))
        await #expect(throws: WebUpdateRefusal.integrity("shared \(Self.react)")) {
            try await store.install(archive: archive, pointer: pointer)
        }
        #expect(!FileManager.default.fileExists(atPath: store.tree(for: pointer.key).root.path))
    }
}
