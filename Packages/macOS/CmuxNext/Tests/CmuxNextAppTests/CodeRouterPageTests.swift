import CmuxNextApps
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The React CodeRouter page's host side (coordinator decision: a separate cmux.coderouter page):
/// `coderouter.detect` from the accounts service works signed out and carries no email, the page
/// provider relays `cmux.coderouter.*` to the same ops the CodeRouter app uses, and the page may run
/// only its four account actions.
@MainActor
struct CodeRouterPageTests {
    private nonisolated final class Calls: @unchecked Sendable {
        var methods: [String] = []
    }

    private static let signedOutAccounts: JSONValue = [
        "signed_in": false, "refreshing": false,
        "providers": [
            ["provider": "codex", "name": "ChatGPT / Codex", "status": "signed_in", "account": "acct_abc",
             "label": "someone@example.com", "plan": "Pro", "phase": "idle", "can_connect": false, "linkable": true,
             "linked": []],
        ],
    ]

    private func ops(_ calls: Calls) -> CodeRouterAppOps {
        CodeRouterAppOps(control: { method, _ throws(AppHostCapabilityError) in
            calls.methods.append(method)
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
        let provider = CodeRouterPageProvider(ops: ops(calls))
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
        #expect(PageID.isFirstParty(page.id))
        #expect(page.admits("cmux.coderouter.status"))
        #expect(page.admits(PageNativeOp.actionRun))
        #expect(!page.admits("cmux.apps.install"))
        #expect(page.actions == ["palette.auth.signIn", "accounts.connect", "accounts.reauthenticate", "accounts.refresh"])
    }
}
