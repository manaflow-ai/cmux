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

    @Test(arguments: ["Runtime.evaluate", "IO.read"])
    func cancellationEndsHeldDevToolsWithoutAnotherRead(_ heldMethod: String) async throws {
        let page = FakeChromiumPage(), entered = AsyncStream<Void>.makeStream()
        var pending: CheckedContinuation<String?, any Error>?
        page.answer = { method, _ in
            switch method {
            case "Runtime.evaluate": return #"{"result":{"objectId":"object"}}"#
            case "IO.resolveBlob": return #"{"uuid":"blob-id"}"#
            default: return #"{"data":"bytes","eof":false}"#
            }
        }
        page.asyncAnswer = { method, _ in
            guard method == heldMethod else { return nil }
            return try await withCheckedThrowingContinuation { pending = $0; entered.continuation.yield() }
        }
        let reader = ChromiumUploadBlobReader(page: page, context: 9, token: "token")
        let request = Task { do { _ = try await reader.next(); return false } catch { return error is CancellationError } }
        var events = entered.stream.makeAsyncIterator()
        _ = await events.next()
        request.cancel()
        let stopped: Bool? = await PageTestWait.value("cancel held DevTools", seconds: 2) { done in
            Task { done(await request.value) }
        }
        pending?.resume(returning: heldMethod == "Runtime.evaluate" ? #"{"result":{"objectId":"object"}}"# : #"{"data":"bytes","eof":false}"#)
        _ = await request.value
        await reader.close()
        let released: Bool? = await PageTestWait.value("release late Blob", seconds: 2) { done in
            @MainActor func check() { if page.calls.contains(where: { $0.method == "Runtime.releaseObject" }) { done(true) } }
            page.onCall = check
            check()
        }
        #expect(stopped == true && released == true)
        #expect(page.calls.filter { $0.method == "IO.read" }.count == (heldMethod == "IO.read" ? 1 : 0))
    }

    @Test(arguments: [true, false])
    func sharedPageUploadEnvelopeRequiresTrustedContext(_ trusted: Bool) async throws {
        let page = FakeChromiumPage()
        if !trusted { page.senderURL = "https://remote.example/" }
        let descriptor = PageDescriptor(id: "test.plain", resource: "test", namespaces: ["cmux.agent."])
        var called = false
        let bridge = ChromiumPageHostBridge(page: page, uploadHandler: { _, context, params, _ in
            #expect(context == 9 && params["token"] as? String == "token")
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
                         "params": ["token": "token", "name": "x", "type": "application/octet-stream", "size": 2,
                                    "sessionId": "s", "promptId": "p", "ticket": "k"]],
            ]))
        }
        #expect(called == trusted)
        #expect(reply?.contains(trusted ? "\"t\":\"ok\"" : "\"t\":\"err\"") == true)
        #expect(reply?.contains(trusted ? "\"uploadId\":\"u\"" : "page.untrusted") == true)
        #expect(reply?.contains("\"id\":7") == true)
        #expect(!page.calls.contains { $0.method == "IO.resolveBlob" })
    }


}
