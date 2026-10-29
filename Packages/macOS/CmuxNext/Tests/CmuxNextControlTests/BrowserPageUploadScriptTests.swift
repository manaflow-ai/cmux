import AppKit
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing
import WebKit

/// Execute the upload scripts against one real input: state isolation must protect
/// file contents, not merely produce different script text.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct BrowserPageUploadScriptTests {
    @MainActor final class PageEngine: BrowserPageEngine {
        let page: BrowserPageSnapshotTests.Page

        init(page: BrowserPageSnapshotTests.Page) { self.page = page }

        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            switch operation {
            case .upload:
                return ["chooser": "withdrawn", "value": ["value": ["fileInput": true]]]
            case let .evaluate(script):
                return ["value": try await page.read(script)]
            default:
                return .null
            }
        }
    }

    @Test func noChooserUploadReconstructsEveryByteAboveFormerLimit() async throws {
        let page = BrowserPageSnapshotTests.Page()
        await page.load()
        defer { page.window.close() }
        _ = try await page.read("(() => { document.body.innerHTML = '<input id=\"upload\" type=\"file\">'; return true; })()")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("upload-large-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        let count = 25 * 1024 * 1024 + 1
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for index in buffer.indices { buffer[index] = UInt8(index % 251) }
        }
        try bytes.write(to: file)

        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        BrowserPageService(engine: PageEngine(page: page)).install(on: router)
        var snapshot = ControlSnapshot.sample()
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(
            ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Form", url: "https://example.com/")
        )
        router.snapshots.publish { $0 = snapshot }
        _ = try await router.handle(ControlRequest(method: "browser.page.upload", params: [
            "tab": "tab_0123abcd", "selector": "#upload", "files": [.string(file.path)],
        ])).get()

        #expect(try await page.read("document.getElementById('upload').files[0].size") == .number(Double(count)))
        let correct = try await page.webView.callAsyncJavaScript(
            "const bytes = new Uint8Array(await document.getElementById('upload').files[0].arrayBuffer()); return bytes.every((byte, index) => byte === index % 251);",
            arguments: [:], in: nil, in: .page
        ) as? Bool
        #expect(correct == true, "the original file must arrive byte-for-byte")
    }

    @Test func interleavedUploadsKeepTheirOwnBytesAndCleanup() async throws {
        let page = BrowserPageSnapshotTests.Page()
        await page.load()
        defer { page.window.close() }
        _ = try await page.read("(() => { document.body.innerHTML = '<input id=\"upload\" type=\"file\">'; window.changes = 0; document.getElementById('upload').addEventListener('change', () => window.changes++); return true; })()")

        func run(_ script: String) async throws -> JSONValue {
            let value = try await page.read(script)
            #expect(value["error"] == nil, "page script failed: \(value)")
            return value
        }
        func chunk(_ id: String, _ text: String) async throws {
            _ = try await run(BrowserPageScripts.uploadChunk("#upload", id: id, index: 0,
                                                           base64: Data(text.utf8).base64EncodedString()))
        }
        func contents() async throws -> String? {
            try await page.webView.callAsyncJavaScript(
                "return await document.getElementById('upload').files[0].text();",
                arguments: [:], in: nil, in: .page
            ) as? String
        }

        _ = try await run(BrowserPageScripts.startUpload("#upload", id: "A", files: [("A.txt", "text/plain")]))
        try await chunk("A", "A-first")
        _ = try await run(BrowserPageScripts.startUpload("#upload", id: "B", files: [("B.txt", "text/plain")]))
        try await chunk("B", "B-first")
        try await chunk("A", "A-second")
        _ = try await run(BrowserPageScripts.finishUpload("#upload", id: "A"))
        #expect(try await contents() == "A-firstA-second")
        #expect(try await page.read("document.getElementById('upload').files[0].name") == "A.txt")

        try await chunk("B", "B-second")
        _ = try await run(BrowserPageScripts.finishUpload("#upload", id: "B"))
        #expect(try await contents() == "B-firstB-second")
        #expect(try await page.read("document.getElementById('upload').files[0].name") == "B.txt")
        #expect(try await page.read("window.changes") == 2)

        _ = try await run(BrowserPageScripts.startUpload("#upload", id: "C", files: [("C.txt", "text/plain")]))
        _ = try await run(BrowserPageScripts.startUpload("#upload", id: "D", files: [("D.txt", "text/plain")]))
        try await chunk("C", "discard")
        try await chunk("D", "keep")
        _ = try await run(BrowserPageScripts.cancelUpload("#upload", id: "C"))
        let cancelled = try await page.read(BrowserPageScripts.finishUpload("#upload", id: "C"))
        #expect(cancelled["code"] == "upload_not_started")
        _ = try await run(BrowserPageScripts.finishUpload("#upload", id: "D"))
        #expect(try await contents() == "keep")
        #expect(try await page.read("window.changes") == 3)
        #expect(try await page.read("Object.keys(document.getElementById('upload').__cmuxUploads).length") == 0)
    }
}
