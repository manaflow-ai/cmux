import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The app's page providers (plans/cmux-next/react-pages.md 1.1, 1.3): typed action arguments by
/// the descriptor's schema, the daemon relay's error mapping and params bridging, and the History
/// page's action allowlist.
struct PageProvidersTests {
    @Test func pageArgumentsBecomeTypedActionArguments() {
        let descriptor = ActionDescriptor(
            id: "history.open", title: "Open History Entry", category: .window,
            arguments: [
                ActionArgument(name: "id", title: "ID", kind: .string, isRequired: true),
                ActionArgument(name: "new_tab", title: "New Tab", kind: .bool, isRequired: false),
            ])
        let args = AppPageNativeProvider.arguments(["id": "page:default:7", "new_tab": true, "extra": ["x": 1]], for: descriptor)
        #expect(args == ["id": .string("page:default:7"), "new_tab": .bool(true)])
        #expect(AppPageNativeProvider.arguments(nil, for: descriptor).isEmpty)
        #expect(AppPageNativeProvider.arguments(["id", "x"], for: descriptor).isEmpty)
    }

    @Test func daemonRefusalsKeepCodeDetailsAndRetryUnderTheCmuxNamespace() {
        let refused = DaemonPageRelay.pageError(.command(cmd: "history.clear", message: "bad range", code: "validation.invalid",
                                                         details: .object(["field": .string("range")]), retryable: false))
        #expect(refused == PageError(code: "cmux.validation.invalid", message: "bad range", retryable: false,
                                     details: ["field": "range"]))
        #expect(DaemonPageRelay.pageError(.notConnected).code == "cmux.protocol.transport")
        #expect(DaemonPageRelay.pageError(.notConnected).retryable)
        #expect(DaemonPageRelay.pageError(.command(cmd: "x", message: "m", code: "cmux.history.gone")).code == "cmux.history.gone")
    }

    @Test func paramsCrossBetweenThePageAndDaemonJSONUnchanged() throws {
        let params: [String: CmuxNextSettings.JSONValue] = ["kinds": ["agent"], "limit": 1000, "text": "café"]
        let daemon = try DaemonPageRelay.daemonParams(params)
        #expect(daemon["limit"] == .number(1000))
        #expect(daemon["text"] == .string("café"))
        #expect(try DaemonPageRelay.pageValue(.object(daemon)) == .object(params))
    }

    @Test func theHistoryPageRunsOnlyHistoryOpen() {
        #expect(PageDescriptor.history.actions == ["history.open"])
        #expect(PageDescriptor.history.admits(PageNativeOp.actionRun))
        #expect(!PageDescriptor.history.admits("cmux.settings.set"))
    }
}
