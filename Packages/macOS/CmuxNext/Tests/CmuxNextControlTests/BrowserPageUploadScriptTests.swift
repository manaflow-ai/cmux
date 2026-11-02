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
        // A window made in code is released by close() unless told not to; under ARC that is an
        // over-release, and the next test died with signal 11.
        defer { page.window.isReleasedWhenClosed = false; page.window.close() }
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
        // `contentWorld:` is the async overload the app uses; the `in:in:` bridge of the completion
        // handler returned nil here and crashed the next test (signal 11) on the fleet.
        let mismatches = try await page.webView.callAsyncJavaScript(
            "const bytes = new Uint8Array(await document.getElementById('upload').files[0].arrayBuffer()); let bad = 0; for (let i = 0; i < bytes.length; i++) if (bytes[i] !== i % 251) bad++; return bytes.length + ':' + bad;",
            arguments: [:], in: nil, contentWorld: .page
        ) as? String
        #expect(mismatches == "\(count):0", "the original file must arrive byte-for-byte")
    }

    @Test func interleavedUploadsKeepTheirOwnBytesAndCleanup() async throws {
        let page = BrowserPageSnapshotTests.Page()
        await page.load()
        // A window made in code is released by close() unless told not to; under ARC that is an
        // over-release, and the next test died with signal 11.
        defer { page.window.isReleasedWhenClosed = false; page.window.close() }
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
                arguments: [:], in: nil, contentWorld: .page
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
        #expect(try await page.read("document.getElementById('upload').__cmuxUploads.size") == 0)
    }

    /// An upload id names one upload on the page. Starting a second upload with an active id is refused.
    @Test func aSecondUploadCannotReuseAnActiveID() async throws {
        let page = BrowserPageSnapshotTests.Page()
        await page.load()
        defer { page.window.isReleasedWhenClosed = false; page.window.close() }
        _ = try await page.read("(() => { document.body.innerHTML = '<input id=\"a\" type=\"file\"><input id=\"b\" type=\"file\">'; return true; })()")
        let first = try await page.read(BrowserPageScripts.startUpload("#a", id: "X", files: [("a.txt", "text/plain")]))
        #expect(first["error"] == nil, "page script failed: \(first)")
        let second = try await page.read(BrowserPageScripts.startUpload("#b", id: "X", files: [("b.txt", "text/plain")]))
        #expect(second["code"] == "upload_id_in_use", "a reused active id was accepted: \(second)")
        #expect(try await page.read("document.getElementById('b').__cmuxUploads === undefined") == true,
                "the refused upload left state on the other input")
        _ = try await page.read(BrowserPageScripts.uploadChunk("#a", id: "X", index: 0, base64: Data("mine".utf8).base64EncodedString()))
        let done = try await page.read(BrowserPageScripts.finishUpload("#a", id: "X"))
        #expect(done["error"] == nil, "page script failed: \(done)")
        #expect(try await page.read("document.getElementById('a').files[0].name") == "a.txt", "the first upload lost its input")
        #expect(try await page.read("document.getElementById('b').files.length") == 0, "the other input got the first upload's file")
    }

    /// A snapshot can move an `eN` ref to another element mid-upload. The upload keeps its own input:
    /// later chunks and the cleanup reach the input it started on, and the other input is untouched.
    @Test func anUploadKeepsItsInputWhenItsRefMovesToAnother() async throws {
        let page = BrowserPageSnapshotTests.Page()
        await page.load()
        // A window made in code is released by close() unless told not to (see above).
        defer { page.window.isReleasedWhenClosed = false; page.window.close() }
        _ = try await page.read("(() => { document.body.innerHTML = '<input id=\"a\" type=\"file\" data-cmux-ref=\"e1\"><input id=\"b\" type=\"file\">'; document.getElementById('b').__cmuxUploads = new Map([['other', { files: [] }]]); return true; })()")

        func run(_ script: String) async throws -> JSONValue {
            let value = try await page.read(script)
            #expect(value["error"] == nil, "page script failed: \(value)")
            return value
        }
        _ = try await run(BrowserPageScripts.startUpload("@e1", id: "R", files: [("R.txt", "text/plain")]))
        _ = try await run(BrowserPageScripts.uploadChunk("@e1", id: "R", index: 0, base64: Data("first".utf8).base64EncodedString()))
        _ = try await page.read("(() => { document.getElementById('a').removeAttribute('data-cmux-ref'); document.getElementById('b').setAttribute('data-cmux-ref', 'e1'); return true; })()")

        let duplicate = try await page.read(BrowserPageScripts.startUpload("@e1", id: "R", files: [("other.txt", "text/plain")]))
        #expect(duplicate["code"] == "upload_id_in_use", "an active id must not be rebound to another input")

        _ = try await run(BrowserPageScripts.uploadChunk("@e1", id: "R", index: 0, base64: Data("second".utf8).base64EncodedString()))
        #expect(try await page.read("document.getElementById('a').__cmuxUploads.get('R').files[0].parts.length") == 2,
                "the chunk after the ref moved missed the upload's own input")
        _ = try await run(BrowserPageScripts.cancelUpload("@e1", id: "R"))

        #expect(try await page.read("document.getElementById('a').__cmuxUploads.size") == 0, "the original input kept the cancelled upload")
        #expect(try await page.read("document.getElementById('b').__cmuxUploads.size") == 1, "cleanup touched the other input")
        #expect(try await page.read("document.getElementById('b').__cmuxUploads.has('other')") == true)
    }
}
