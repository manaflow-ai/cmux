import AppKit
@testable import CmuxNextPages
import CmuxNextSettings
import Testing

/// The native confirmation in front of page calls that need a person (coordinator Q4): a declined
/// call never reaches the owner; an approved one reaches it marked confirmed; other calls pass.
@MainActor
@Suite struct ConfirmingPageProviderTests {
    final class Inner: PageProvider {
        var calls: [(String, PageCallContext)] = []
        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            calls.append((op, context))
            return ["status": "done"]
        }
    }

    final class Presenter: PageConfirmationPresenter {
        var answer: Bool
        var shown: [PageConfirmation] = []
        init(answer: Bool) { self.answer = answer }
        func confirm(_ confirmation: PageConfirmation, anchor: NSView?) async -> Bool {
            shown.append(confirmation)
            return answer
        }
    }

    static let install = PageConfirmation(
        kind: .install, name: "Gmail",
        scopes: [.init(scope: "workspace:read", reason: "Matches threads to workspaces.", risk: "standard"),
                 .init(scope: "terminal:input", reason: "Types into a terminal.", risk: "restricted")],
        webURL: "https://mail.google.com/mail/u/0/", webOrigins: ["https://accounts.google.com"])

    func provider(answer: Bool) -> (ConfirmingPageProvider, Inner, Presenter) {
        let inner = Inner()
        let presenter = Presenter(answer: answer)
        let provider = ConfirmingPageProvider(inner: inner, presenter: presenter) { op, _ in
            op == "cmux.apps.install" ? Self.install : nil
        }
        return (provider, inner, presenter)
    }

    @Test func aDeclinedCallNeverReachesTheOwner() async {
        let (provider, inner, presenter) = provider(answer: false)
        await #expect(throws: PageError.cancelled) {
            try await provider.call("cmux.apps.install", params: ["app": "gmail"], context: PageCallContext(page: "cmux.apps"))
        }
        #expect(inner.calls.isEmpty)
        #expect(presenter.shown == [Self.install])
    }

    @Test func anApprovedCallReachesTheOwnerConfirmed() async throws {
        let (provider, inner, _) = provider(answer: true)
        _ = try await provider.call("cmux.apps.install", params: ["app": "gmail"], context: PageCallContext(page: "cmux.apps"))
        #expect(inner.calls.map(\.0) == ["cmux.apps.install"])
        #expect(inner.calls.first?.1 == PageCallContext(page: "cmux.apps", origin: "user", confirmed: true))
    }

    @Test func callsWithoutASheetPassUnconfirmed() async throws {
        let (provider, inner, presenter) = provider(answer: false)
        _ = try await provider.call("cmux.apps.catalog.list", params: [:], context: PageCallContext(page: "cmux.apps"))
        #expect(inner.calls.first?.1.confirmed == false)
        #expect(inner.calls.first?.1.origin == "page", "without a sheet the call stays the page's")
        #expect(inner.calls.first?.1.isConfirmedUser == false)
        #expect(presenter.shown.isEmpty)
    }

    @Test func theSheetListsScopesRiskiestFirstAndTheWebOrigins() {
        let lines = Self.install.lines
        #expect(lines.first == PageStrings.asksFor)
        #expect(lines[1].hasPrefix("• terminal:input ("))
        #expect(lines[2].hasPrefix("• workspace:read ("))
        #expect(lines.suffix(2) == ["• https://mail.google.com/mail/u/0/", "• https://accounts.google.com"])
        #expect(Self.install.title.contains("Gmail"))
        #expect(!Self.install.isDestructive)
        #expect(PageConfirmation(kind: .uninstall, name: "Gmail").isDestructive)
    }
}
