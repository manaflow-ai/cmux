import CmuxNextApps
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The React CodeRouter page's host side (coordinator decision: a separate cmux.coderouter page):
/// `coderouter.detect` from the accounts service works signed out and carries no email, the page
/// provider relays `cmux.coderouter.*` to the same ops the CodeRouter app uses, and the page may run
/// only its three account actions; Connect passes the native sheet.
@MainActor
struct CodeRouterPageTests {
    private nonisolated final class Calls: @unchecked Sendable {
        var methods: [String] = []
        var origins: [String] = []
    }

    nonisolated private static let signedOutAccounts: JSONValue = [
        "signed_in": false, "refreshing": false,
        "providers": [
            ["provider": "codex", "name": "ChatGPT / Codex", "status": "signed_in", "account": "acct_abc",
             "label": "someone@example.com", "plan": "Pro", "phase": "idle", "can_connect": false, "linkable": true,
             "linked": []],
        ],
    ]

    private func ops(_ calls: Calls) -> CodeRouterAppOps {
        CodeRouterAppOps(control: { method, params throws(AppHostCapabilityError) in
            calls.methods.append(method)
            calls.origins.append(params["origin"]?.stringValue ?? "")
            return Self.signedOutAccounts
        })
    }

    @Test func detectWorksSignedOutAndShowsNoEmail() async throws {
        let calls = Calls()
        let value = try await ops(calls).handle(
            AppHostCapabilityRequest(app: "cmux/coderouter", op: "coderouter.detect", params: .object([:]), origin: "user"))
        let providers = value["providers"]?.arrayValue ?? []
        #expect(providers.count == 1)
        #expect(providers.first?["provider"]?.stringValue == "codex")
        #expect(providers.first?["account"]?.stringValue == "acct_abc")
        #expect(!String(describing: value).contains("someone@example.com"))
        #expect(calls.methods == ["accounts.list"])
    }

    @Test func thePageProviderRelaysItsNamespaceToTheCodeRouterOps() async throws {
        let calls = Calls()
        let provider = CodeRouterPageProvider(ops: ops(calls), connect: { _ in true })
        let context = PageCallContext(page: PageDescriptor.coderouter.id)
        let status = try await provider.call("cmux.coderouter.status", params: [:], context: context)
        #expect(status["signed_in"]?.boolValue == false)
        let detect = try await provider.call("cmux.coderouter.detect", params: [:], context: context)
        #expect(detect["providers"]?.arrayValue?.count == 1)
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.coderouter.keys.list", params: [:], context: context)
        }
        do {
            _ = try await provider.call("cmux.coderouter.keys.list", params: [:], context: context)
        } catch let error as PageError {
            #expect(error.code == "cmux.operation.unsupported")
        }
    }

    @Test func thePageRunsOnlyItsAccountActions() {
        let page = PageDescriptor.coderouter
        // A reserved id served only from the bundle, with the strict policy; it needs no
        // first-party entry (that table only widens a CSP and lists Chromium-tab pages).
        #expect(PageID.isReserved(page.id))
        #expect(!PageID.isFirstParty(page.id))
        #expect(page.csp == .strict)
        #expect(page.admits("cmux.coderouter.status"))
        #expect(page.admits(PageNativeOp.actionRun))
        #expect(!page.admits("cmux.apps.install"))
        #expect(page.actions == ["palette.auth.signIn", "accounts.reauthenticate", "accounts.refresh"])
        // Connect adds a credential: never a plain action; the page calls the host op, which the
        // host puts behind its native sheet (ConfirmingPageProvider + CodeRouterPageConfirmations).
        #expect(!page.actions.contains("accounts.connect"))
    }

    /// A page call is the user's own only after the native sheet (context.confirmed).
    @Test func onlyAConfirmedCallReachesTheOwnerAsTheUser() async throws {
        let calls = Calls()
        let provider = CodeRouterPageProvider(ops: ops(calls), connect: { _ in true })
        _ = try await provider.call("cmux.coderouter.status", params: [:], context: PageCallContext(page: "cmux.coderouter"))
        _ = try await provider.call("cmux.coderouter.status", params: [:],
                                    context: PageCallContext(page: "cmux.coderouter", origin: "user", confirmed: true))
        #expect(calls.origins == ["script", "user"])
    }

    /// Connect runs only after the sheet: unconfirmed it is refused and never reaches the action.
    @Test func connectNeedsTheNativeSheet() async throws {
        var connected: [String] = []
        let provider = CodeRouterPageProvider(ops: ops(Calls()), connect: { connected.append($0); return true })
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.coderouter.accounts.connect", params: ["provider": "codex"],
                                    context: PageCallContext(page: "cmux.coderouter"))
        }
        #expect(connected.isEmpty)
        let value = try await provider.call("cmux.coderouter.accounts.connect", params: ["provider": "codex"],
                                            context: PageCallContext(page: "cmux.coderouter", origin: "user", confirmed: true))
        #expect(connected == ["codex"])
        #expect(value["connected"]?.boolValue == true)
        let sheet = CodeRouterPageConfirmations.confirmation(
            op: "cmux.coderouter.accounts.connect", params: ["provider": "codex", "name": "ChatGPT / Codex"])
        #expect(sheet?.kind == .custom)
        #expect(sheet?.name.contains("ChatGPT / Codex") == true)
        #expect(sheet?.detail?.isEmpty == false)
        #expect(CodeRouterPageConfirmations.confirmation(op: "cmux.coderouter.status", params: [:]) == nil)
    }

    /// A document that is not the bundled page never reaches the bridge: a foreign URL in the
    /// tab is not trusted, and the page's navigation policy never loads one (no hook).
    @Test func aForeignDocumentInTheTabGetsNoBridge() {
        let page = PageDescriptor.coderouter
        #expect(PageHostTrust.isTrusted(PageHostMessage(frameURL: URL(string: "cmux-page://cmux.coderouter/"), isMainFrame: true, body: [:]),
                                        page: page))
        for foreign in ["https://example.com/", "cmux-page://cmux.apps/", "cmux-page://evil.coderouter/", "file:///tmp/x.html"] {
            #expect(!PageHostTrust.isTrusted(PageHostMessage(frameURL: URL(string: foreign), isMainFrame: true, body: [:]), page: page))
            for clicked in [true, false] {
                #expect(PageNavigation.policy(for: URL(string: foreign), page: page, userClicked: clicked, mainFrame: true,
                                              hook: nil) != .allow)
            }
        }
        // A frame inside the page is never trusted, even at the page's own origin.
        #expect(!PageHostTrust.isTrusted(PageHostMessage(frameURL: URL(string: "cmux-page://cmux.coderouter/"), isMainFrame: false,
                                                         body: [:]), page: page))
    }
}
