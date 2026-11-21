import CmuxNextSettings
@testable import CmuxNextPages
import Testing

/// A provider that fails with anything but a ``PageError`` (a daemon refusal, a file error) never
/// sends its Swift Debug text as the reply's `message`, which pages used to show as is: the page
/// gets a fixed message and the code, and the Debug text only in `details.reason` (and the log).
@MainActor
struct PageRouterPlainFailureTests {
    static let descriptor = PageDescriptor(id: "cmux.plain-test", resource: "plain-test", namespaces: ["cmux.plain."])

    struct OwnerRefusal: Error {
        let cmd = "page.read"
        let message = "socket path exceeds sun_path"
    }

    final class FailingProvider: PageProvider {
        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            throw OwnerRefusal()
        }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            throw OwnerRefusal()
        }
    }

    private func router() -> PageRouter {
        PageRouter(descriptor: Self.descriptor, routes: [PageRoute(prefix: "cmux.plain.", provider: FailingProvider())])
    }

    @Test func aFailedCallSendsAFixedMessageAndKeepsTheDebugTextInDetails() async {
        let reply = await router().handle(["t": "call", "id": 1, "op": "cmux.plain.read", "params": [:]])
        #expect(reply["t"]?.stringValue == "err")
        #expect(reply["code"]?.stringValue == "cmux.page.failed")
        #expect(reply["message"]?.stringValue == PageError.failedMessage)
        #expect(reply["message"]?.stringValue?.contains("sun_path") == false)
        #expect(reply["details"]?["reason"]?.stringValue?.contains("sun_path") == true)
    }

    @Test func aFailedSubscribeSendsAFixedMessageToo() async {
        let reply = await router().handle(["t": "sub", "id": 2, "stream": "cmux.plain.changes"])
        #expect(reply["code"]?.stringValue == "cmux.page.failed")
        #expect(reply["message"]?.stringValue == PageError.failedMessage)
        #expect(reply["details"]?["reason"]?.stringValue?.contains("OwnerRefusal") == true)
    }
}
