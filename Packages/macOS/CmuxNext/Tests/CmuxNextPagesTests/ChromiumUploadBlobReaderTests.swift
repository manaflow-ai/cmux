import Foundation
import JavaScriptCore
import Testing
@testable import CmuxNextPages
import CmuxNextPagesTestSupport

@MainActor
struct ChromiumUploadBlobReaderTests {
    @Test func eachNextReadsOneChunkWithBlobHandleAndReleasesObject() async throws {
        let page = FakeChromiumPage()
        var reads = 0
        page.answer = { method, _ in
            switch method {
            case "Runtime.evaluate": return #"{"result":{"type":"object","className":"Blob","objectId":"object"}}"#
            case "IO.resolveBlob": return #"{"uuid":"blob-id"}"#
            case "IO.read":
                reads += 1
                return reads == 1
                    ? #"{"data":"YWJj","base64Encoded":false,"eof":false}"#
                    : #"{"data":"AP8=","base64Encoded":true,"eof":true}"#
            default: return "{}"
            }
        }
        let reader = ChromiumUploadBlobReader(page: page, context: 9, token: "token")
        #expect(reads == 0)
        #expect(try await reader.next() == Data("YWJj".utf8))
        #expect(reads == 1)
        #expect(try await reader.next() == Data([0, 255]))
        #expect(reads == 2)
        #expect(try await reader.next() == nil)
        await reader.close()
        #expect(page.calls.filter { $0.method == "IO.read" }.allSatisfy { $0.params["handle"] as? String == "blob:blob-id" })
        #expect(page.calls.contains { $0.method == "IO.close" && $0.params["handle"] as? String == "blob:blob-id" })
        #expect(page.calls.contains { $0.method == "Runtime.releaseObject" && $0.params["objectId"] as? String == "object" })
        #expect(page.calls.first?.params["contextId"] as? Int == 9)
    }

    @Test func missingBlobIsRefusedWithoutReadingBytes() async {
        let page = FakeChromiumPage()
        let reader = ChromiumUploadBlobReader(page: page, context: 11, token: "missing")
        await #expect(throws: AgentPageUploadError.invalidBlob) { try await reader.next() }
        #expect(!page.calls.contains { $0.method == "IO.read" })
    }
    @Test func sharedPageUploadCallReturnsTypedReplyAfterFinish() async throws {
        let page = FakeChromiumPage()
        let descriptor = PageDescriptor(id: "test.plain", resource: "test", namespaces: ["cmux.agent."])
        var called = false
        let bridge = ChromiumPageHostBridge(page: page, uploadHandler: { _, context, params, _ in
            #expect(context == 9)
            #expect(params["token"] as? String == "token")
            called = true
            return ["ok": true, "value": ["token": "token", "uploadId": "u", "size": 2]]
        }, descriptor: descriptor)
        bridge.install { _ in ["t": "err", "id": 7, "code": "cmux.protocol.unknown_op"] }
        let reply: String? = await PageTestWait.value("upload reply") { done in
            page.onCall = {
                if let expression = page.calls.last?.params["expression"] as? String,
                   expression.contains(ChromiumPageHostBridge.resolveName) { done(expression) }
            }
            bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall([
                "name": "cmuxPage", "seq": 1,
                "body": ["t": "call", "id": 7, "op": "cmux.agent.uploads.begin",
                         "params": ["token": "token", "name": "x", "type": "application/octet-stream", "size": 2, "sessionId": "s"]],
            ]))
        }
        #expect(called)
        #expect(reply?.contains("\"t\":\"ok\"") == true)
        #expect(reply?.contains("\"uploadId\":\"u\"") == true)
        #expect(reply?.contains("\"id\":7") == true)
    }

    @Test func untrustedUploadCallReturnsTypedErrorWithoutReadingBlob() async {
        let page = FakeChromiumPage()
        page.senderURL = "https://remote.example/"
        let descriptor = PageDescriptor(id: "test.plain", resource: "test", namespaces: ["cmux.agent."])
        var called = false
        let bridge = ChromiumPageHostBridge(page: page, uploadHandler: { _, _, _, _ in called = true; return nil }, descriptor: descriptor)
        bridge.install { _ in nil }
        let reply: String? = await PageTestWait.value("untrusted reply") { done in
            page.onCall = {
                if let expression = page.calls.last?.params["expression"] as? String,
                   expression.contains(ChromiumPageHostBridge.resolveName) { done(expression) }
            }
            bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall([
                "name": "cmuxPage", "seq": 1,
                "body": ["t": "call", "id": 7, "op": "cmux.agent.uploads.begin", "params": [:]],
            ]))
        }
        #expect(!called)
        #expect(reply?.contains("\"t\":\"err\"") == true)
        #expect(reply?.contains("page.untrusted") == true)
        #expect(!page.calls.contains { $0.method == "IO.resolveBlob" })
    }
    @Test func nativeUploadCapabilityIsAdvertisedOnlyWhenInstalled() throws {
        for installed in [false, true] {
            let context = try #require(JSContext())
            let calls = ChromiumPageHostBridge.setupCalls(handlers: [], documentScripts: [], supportsUploads: installed)
            for (method, params) in calls where method == "Page.addScriptToEvaluateOnNewDocument" {
                context.evaluateScript(params["source"] as? String ?? "")
            }
            #expect(context.evaluateScript("globalThis.__cmuxNativePromptUploads === true").toBool() == installed)
        }
    }
}
