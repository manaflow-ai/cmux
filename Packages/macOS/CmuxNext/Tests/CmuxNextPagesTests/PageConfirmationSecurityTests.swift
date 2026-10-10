import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextSettings
import Testing

/// The page confirmation is a security gate (App Store install, CodeRouter
/// Connect): `context.confirmed` is set only after the person confirms the
/// native cmux dialog. Cancel, Escape and a dismissal never confirm, and a
/// page cannot open or answer the dialog itself.
@MainActor
struct PageConfirmationSecurityTests {
    final class Inner: PageProvider {
        var calls: [(String, PageCallContext)] = []
        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            calls.append((op, context))
            return ["status": "done"]
        }
    }

    static let connect = PageConfirmation(kind: .custom, name: "Connect CodeRouter")

    static func make() -> (ConfirmingPageProvider, Inner, CmuxDialogCenter) {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        let inner = Inner()
        let provider = ConfirmingPageProvider(inner: inner, presenter: DialogPageConfirmationPresenter(center: center)) { op, _ in
            op == "cmux.coderouter.connect" ? Self.connect : nil
        }
        return (provider, inner, center)
    }

    /// Starts a Connect call and waits until its dialog shows.
    static func startConnect(_ provider: ConfirmingPageProvider, _ center: CmuxDialogCenter,
                             context: PageCallContext = PageCallContext(page: "cmux.coderouter"))
        async -> (Task<JSONValue, any Error>, Int?) {
        let task = Task { try await provider.call("cmux.coderouter.connect", params: ["provider": "codex"], context: context) }
        for _ in 0..<500 where center.records.isEmpty { await Task.yield() }
        return (task, center.records.first?.id)
    }

    static func expectNotConfirmed(_ task: Task<JSONValue, any Error>, _ inner: Inner) async {
        await #expect(throws: PageError.cancelled) { try await task.value }
        #expect(inner.calls.isEmpty, "the owner never sees an unconfirmed Connect")
    }

    @Test func connectCancelledIsNotConfirmed() async throws {
        let (provider, inner, center) = Self.make()
        let (task, id) = await Self.startConnect(provider, center)
        #expect(center.press(try #require(id), button: "cancel"))
        await Self.expectNotConfirmed(task, inner)
    }

    @Test func connectDismissedByEscapeIsNotConfirmed() async throws {
        let (provider, inner, center) = Self.make()
        let (task, id) = await Self.startConnect(provider, center)
        #expect(center.key(.escape, in: try #require(id)))
        await Self.expectNotConfirmed(task, inner)
    }

    /// A click outside a modal dialog does not answer it; when the dialog
    /// ends without a press (its window or tab closed), Connect is not confirmed.
    @Test func connectDismissedWithoutAPressIsNotConfirmed() async throws {
        let (provider, inner, center) = Self.make()
        let (task, id) = await Self.startConnect(provider, center)
        #expect(center.dismiss(try #require(id)))
        await Self.expectNotConfirmed(task, inner)
    }

    @Test func onlyThePersonsConfirmSetsConfirmed() async throws {
        let (provider, inner, center) = Self.make()
        let (task, id) = await Self.startConnect(provider, center)
        #expect(center.press(try #require(id), button: "confirm"))
        _ = try await task.value
        #expect(inner.calls.first?.1 == PageCallContext(page: "cmux.coderouter", origin: "user", confirmed: true))
    }

    /// The page cannot answer for the person: a call that claims
    /// `confirmed`, and page calls made while the dialog shows, neither
    /// confirm Connect nor touch the dialog.
    @Test func aPageCannotOpenOrAnswerTheConfirmation() async throws {
        let (provider, inner, center) = Self.make()
        let forged = PageCallContext(page: "cmux.coderouter", origin: "user", confirmed: true)
        let (task, id) = await Self.startConnect(provider, center, context: forged)
        let dialog = try #require(id)
        for op in ["cmux.dialog.press", "cmux.app.action.run", "debug.dialog"] {
            _ = try? await provider.call(op, params: ["id": .number(Double(dialog)), "press": "confirm", "button": "confirm"],
                                         context: forged)
        }
        #expect(center.records.map(\.id) == [dialog], "the dialog still waits for the person")
        #expect(inner.calls.allSatisfy { $0.0 != "cmux.coderouter.connect" }, "Connect has not reached the owner")
        #expect(center.press(dialog, button: "cancel"))
        await #expect(throws: PageError.cancelled) { try await task.value }
        #expect(inner.calls.allSatisfy { $0.0 != "cmux.coderouter.connect" })
    }
}
