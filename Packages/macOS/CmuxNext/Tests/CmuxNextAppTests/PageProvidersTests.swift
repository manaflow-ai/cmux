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

    /// The Passwords page's Import buttons run the person-only import actions through the
    /// registry (PASSWORDS-IMPORT-ANY-BROWSER): only those two, and only on a real click or key in
    /// the page. Page script alone cannot put the import window or the file picker in front of
    /// the person.
    @Test func thePasswordsPageRunsTheImportActionsOnlyOnAGesture() async throws {
        #expect(PageDescriptor.passwords.actions == ["importFromBrowser", "password.importCSV"])
        #expect(PageDescriptor.passwords.admits(PageNativeOp.actionRun))
        let native = AppPageNativeProvider(services: ActionBindingCoverageTests.boundServices(), page: .passwords)
        for action in ["importFromBrowser", "password.importCSV"] {
            do {
                _ = try await native.call(PageNativeOp.actionRun, params: ["action": .string(action)],
                                          context: PageCallContext(page: PageDescriptor.passwords.id))
                Issue.record("\(action) ran without a gesture")
            } catch let error as PageError {
                #expect(error.code == "cmux.app.user_only", "\(action)")
            }
        }
        do {
            _ = try await native.call(PageNativeOp.actionRun, params: ["action": "passwords.open"],
                                      context: PageCallContext(page: PageDescriptor.passwords.id, userGesture: true))
            Issue.record("passwords.open is not an action of the Passwords page")
        } catch let error as PageError {
            #expect(error.code == "cmux.app.action_refused")
        }
    }

    /// cx-qoxe: a page writes the pasteboard only right after the person's own key, click or
    /// native menu choice in that page view (`PageCallContext.userGesture`, tracked by the host's
    /// PageWKWebView, never trusted from page script). Script alone cannot replace the clipboard.
    @Test func aPageWritesTheClipboardOnlyOnTheUsersGesture() async throws {
        let native = AppPageNativeProvider(services: ActionBindingCoverageTests.boundServices(), page: .history)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        native.pasteboard = pasteboard
        pasteboard.clearContents()
        pasteboard.setString("mine", forType: .string)
        do {
            _ = try await native.call(PageNativeOp.clipboardWrite, params: ["text": "page script"],
                                      context: PageCallContext(page: PageDescriptor.history.id))
            Issue.record("the clipboard write ran without a gesture")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        #expect(pasteboard.string(forType: .string) == "mine")

        _ = try await native.call(PageNativeOp.clipboardWrite, params: ["text": "https://example.com"],
                                  context: PageCallContext(page: PageDescriptor.history.id, userGesture: true))
        #expect(pasteboard.string(forType: .string) == "https://example.com")
    }
}
