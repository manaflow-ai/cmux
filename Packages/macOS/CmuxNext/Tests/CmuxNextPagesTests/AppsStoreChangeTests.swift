import AppKit
import CmuxNextPages
import CmuxNextSettings
import Testing

/// `cmux apps install|remove` (AppsStoreChange) through the App Store's confirming provider: the
/// consent card names the app and the deploy target, a decline changes nothing, and only an
/// approved change reaches the supervisor as the user's.
@MainActor
struct AppsStoreChangeTests {
    @MainActor final class Presenter: PageConfirmationPresenter {
        var answer: Bool
        var shown: [PageConfirmation] = []
        init(answer: Bool) { self.answer = answer }
        func confirm(_ confirmation: PageConfirmation, anchor: NSView?) async -> Bool {
            shown.append(confirmation)
            return answer
        }
    }

    @MainActor final class Owner: PageProvider {
        var calls: [(op: String, params: JSONValue, context: PageCallContext)] = []
        var error: PageError?
        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            calls.append((op, params, context))
            if let error { throw error }
            return .object([:])
        }
        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription { PageSubscription {} }
    }

    private func store(_ owner: Owner, _ presenter: Presenter) -> ConfirmingPageProvider {
        ConfirmingPageProvider(inner: owner, presenter: presenter) { op, params in
            AppsPageConfirmations().confirmation(op: op, params: params, detail: ["name": "Hello Deploy", "scopes": []])
        }
    }

    @Test func anApprovedInstallWithADeployTargetReachesTheOwnerAsTheUser() async throws {
        let owner = Owner(), presenter = Presenter(answer: true)
        let change = AppsStoreChange(kind: .install, app: " manaflow-ai/hello-deploy ", deploy: "self-hosted:build-01", idempotencyKey: "k1")
        #expect(await change.send(through: store(owner, presenter)) == .done)
        let card = try #require(presenter.shown.first)
        #expect(card.kind == .install && card.name == "Hello Deploy")
        #expect(card.lines.contains { $0.contains("self-hosted:build-01") }, "the card names the machine")
        let call = try #require(owner.calls.first)
        #expect(call.op == "cmux.apps.install")
        #expect(call.context.origin == "user" && call.context.confirmed)
        #expect(call.params["app"]?.stringValue == "manaflow-ai/hello-deploy")
        #expect(call.params["deploy"]?["target"]?.stringValue == "self-hosted:build-01")
        #expect(call.params["idempotency_key"]?.stringValue == "k1")
    }

    @Test func aDeclinedCardChangesNothing() async {
        let owner = Owner(), presenter = Presenter(answer: false)
        #expect(await AppsStoreChange(kind: .remove, app: "manaflow-ai/standup").send(through: store(owner, presenter)) == .declined)
        #expect(owner.calls.isEmpty)
        #expect(presenter.shown.first?.kind == .uninstall)
    }

    @Test func anUnknownAppAndARefusalAreReported() async {
        let owner = Owner(), presenter = Presenter(answer: true)
        owner.error = PageError(code: "cmux.operation.failed", message: "no such app", details: ["code": "apps.unknown"])
        #expect(await AppsStoreChange(kind: .install, app: "acme/none").send(through: store(owner, presenter)) == .unknownApp)
        owner.error = PageError(code: "cmux.operation.failed", message: "acme/x does not deploy to team-vm",
                                details: ["code": "deploy.target_not_allowed"])
        #expect(await AppsStoreChange(kind: .install, app: "acme/x", deploy: "team-vm:t").send(through: store(owner, presenter))
            == .refused(code: "deploy.target_not_allowed", message: "acme/x does not deploy to team-vm"))
    }

    /// The App Store page's own click is the confirmation: install, update, turn on and allow go
    /// with no sheet, as the user's, and the click is spent. Page script alone (no click), the
    /// same click again, Remove (it deletes the app's data), sandbox off and a deploying install
    /// still show the sheet.
    @Test func thePersonsClickInThePageIsTheConfirmation() async throws {
        let owner = Owner(), presenter = Presenter(answer: true)
        let provider = store(owner, presenter)
        var event = 1_000.0
        func click() -> PageCallContext {
            event += 1
            return PageCallContext(page: "cmux.apps", userGesture: true, gestureEvent: event)
        }
        let clicked: [(String, JSONValue)] = [
            ("cmux.apps.install", ["app": "a/b"]), ("cmux.apps.update", ["app": "a/b"]),
            ("cmux.apps.set", ["app": "a/b", "enabled": true]), ("cmux.apps.set", ["app": "a/b", "sandboxed": true]),
            ("cmux.apps.grant.set", ["app": "a/b", "scope": "net.fetch", "granted": true]),
        ]
        for (op, params) in clicked {
            _ = try await provider.call(op, params: params, context: click())
        }
        #expect(presenter.shown.isEmpty, "no sheet after the person's click")
        #expect(owner.calls.map { $0.op } == clicked.map { $0.0 })
        #expect(owner.calls.allSatisfy { $0.context.isConfirmedUser })

        let again = click()
        _ = try await provider.call("cmux.apps.install", params: ["app": "a/b"], context: again)
        _ = try await provider.call("cmux.apps.install", params: ["app": "a/b"], context: again)
        _ = try await provider.call("cmux.apps.install", params: ["app": "a/b"], context: PageCallContext(page: "cmux.apps"))
        #expect(presenter.shown.count == 2, "the same click again and page script alone ask")

        presenter.shown = []
        let asks: [(String, JSONValue)] = [
            ("cmux.apps.uninstall", ["app": "a/b"]), ("cmux.apps.set", ["app": "a/b", "sandboxed": false]),
            ("cmux.apps.install", ["app": "a/b", "deploy": ["target": "self-hosted:h"]]),
        ]
        for (op, params) in asks {
            _ = try await provider.call(op, params: params, context: click())
        }
        #expect(presenter.shown.count == asks.count, "these ask even after the click")
        #expect(owner.calls.suffix(asks.count).allSatisfy { $0.context.isConfirmedUser })
    }

    @Test func aDeclinedSheetAfterAClickStillChangesNothing() async {
        let owner = Owner(), presenter = Presenter(answer: false)
        await #expect(throws: PageError.cancelled) {
            _ = try await store(owner, presenter).call("cmux.apps.uninstall", params: ["app": "a/b"],
                                                       context: PageCallContext(page: "cmux.apps", userGesture: true, gestureEvent: 5))
        }
        #expect(owner.calls.isEmpty && presenter.shown.count == 1)
    }

    @Test func aRemovalNeverCarriesADeploy() {
        let change = AppsStoreChange(kind: .remove, app: "a/b", deploy: "self-hosted:h")
        #expect(change.deploy == nil && change.op == "cmux.apps.uninstall")
        #expect(change.params["deploy"] == nil && change.params["grant_optional"] == nil)
    }
}
