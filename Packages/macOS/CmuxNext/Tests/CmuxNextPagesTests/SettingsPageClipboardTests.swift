@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// cx-k9go: a Settings row's Copy Setting Key writes the pasteboard through the host's
/// `cmux.app.clipboard.write`, so the Settings page's router admits it.
@MainActor
@Suite struct SettingsPageClipboardTests {
    final class Native: PageProvider {
        var ops: [String] = []

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            ops.append(op)
            return [:]
        }
    }

    @Test func theSettingsPageMayWriteThePasteboard() async {
        let native = Native()
        let router = PageRouter(descriptor: .settings, routes: [PageRoute(prefix: "cmux.app.", provider: native)])
        let reply = await router.handle(["t": "call", "id": 1, "op": .string(PageNativeOp.clipboardWrite),
                                         "params": ["text": "terminal.fontSize"]])
        #expect(reply["t"] == "ok")
        #expect(native.ops == [PageNativeOp.clipboardWrite])
    }
}
