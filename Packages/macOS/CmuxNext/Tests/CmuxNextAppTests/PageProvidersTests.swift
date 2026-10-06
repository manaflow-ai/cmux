import AppKit
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
@MainActor
struct PageProvidersTests {
    final class Presenter: PageConfirmationPresenter {
        var answer: Bool
        var shown: [PageConfirmation] = []
        init(answer: Bool) { self.answer = answer }
        func confirm(_ confirmation: PageConfirmation, anchor: NSView?) async -> Bool {
            shown.append(confirmation)
            return answer
        }
    }

    func cloudNative(answer: Bool) -> (AppPageNativeProvider, Presenter, Box) {
        let native = AppPageNativeProvider(services: ActionBindingCoverageTests.boundServices(), page: .cloud)
        let presenter = Presenter(answer: answer)
        let forwarded = Box()
        native.presenter = presenter
        native.forward = { op, params, context in
            forwarded.calls.append((op, params, context))
            return ["revision": "7"]
        }
        return (native, presenter, forwarded)
    }

    final class Box { var calls: [(String, CmuxNextSettings.JSONValue, PageCallContext)] = [] }

    @Test func aDeclinedCloudDeleteAnswersNotConfirmedAndRunsNothing() async throws {
        let (native, presenter, forwarded) = cloudNative(answer: false)
        let reply = try await native.call(PageNativeOp.actionRun, params: [
            "action": "cmux.cloud.machine.delete", "args": ["machine": "vm_1", "displayName": "api-dev", "idempotency_key": "k"],
        ], context: PageCallContext(page: "cmux.cloud"))
        #expect(reply == ["confirmed": false])
        #expect(forwarded.calls.isEmpty)
        #expect(presenter.shown.first?.kind == .delete && presenter.shown.first?.name == "api-dev")
    }

    @Test func anApprovedCloudDeleteRunsTheOpAsTheUsersOwn() async throws {
        let (native, _, forwarded) = cloudNative(answer: true)
        let reply = try await native.call(PageNativeOp.actionRun, params: [
            "action": "cmux.cloud.machine.delete", "args": ["machine": "vm_1", "idempotency_key": "k"],
        ], context: PageCallContext(page: "cmux.cloud"))
        #expect(reply == ["confirmed": true, "value": ["revision": "7"]])
        #expect(forwarded.calls.first?.0 == "cmux.cloud.machine.delete")
        #expect(forwarded.calls.first?.1 == ["machine": "vm_1", "idempotency_key": "k"])
        #expect(forwarded.calls.first?.2 == PageCallContext(page: "cmux.cloud", origin: "user", confirmed: true))
    }

    @Test func theCloudPageCannotCallAConfirmedOpDirectly() {
        #expect(!PageDescriptor.cloud.admits("cmux.cloud.machine.delete"))
        #expect(!PageDescriptor.cloud.admits("cmux.cloud.billing.open"))
        #expect(PageDescriptor.cloud.admits("cmux.cloud.machine.create"))
        #expect(PageDescriptor.cloud.admits(PageNativeOp.actionRun))
    }

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
        #expect(DaemonPageRelay.pageError(.notConnected).code == "cmux.protocol.closed")
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
