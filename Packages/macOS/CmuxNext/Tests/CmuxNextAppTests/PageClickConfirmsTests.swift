import AppKit
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Testing

/// A person's fresh click in one of our pages is the confirmation (ceremony audit, Leo 2026-11-17:
/// "go remove this ... bullshit belt and suspenders"): the Cloud page's confirmed ops and
/// CodeRouter's Connect run as the user's with no native sheet, and the click is spent. Page
/// script alone, or the same click again, still gets the sheet, and so do the ops that lose data
/// for good or open a machine to the internet.
@MainActor @Suite(.serialized)
struct PageClickConfirmsTests {
    @MainActor final class Presenter: PageConfirmationPresenter {
        var answer = true
        var shown: [PageConfirmation] = []
        func confirm(_ confirmation: PageConfirmation, anchor: NSView?) async -> Bool {
            shown.append(confirmation)
            return answer
        }
    }

    @MainActor final class Recorder: PageProvider {
        var calls: [(op: String, context: PageCallContext)] = []
        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            calls.append((op, context))
            return ["ok": true]
        }
    }

    /// Each click is a new key or mouse event (its uptime).
    @MainActor final class Clicks {
        var event = 2_000.0
        func next(_ page: String = PageDescriptor.cloud.id) -> PageCallContext {
            event += 1
            return PageCallContext(page: page, userGesture: true, gestureEvent: event)
        }
    }

    private let clicks = Clicks()

    private func cloud(_ presenter: Presenter, _ recorder: Recorder) -> AppPageNativeProvider {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let native = AppPageNativeProvider(services: services, page: .cloud)
        native.presenter = presenter
        // The provider holds its services unowned: the forward keeps them for the test.
        native.forward = { [services] op, params, context in
            _ = services
            return try await recorder.call(op, params: params, context: context)
        }
        return native
    }

    private func run(_ op: String) -> JSONValue {
        ["action": .string(op), "args": ["machine": "m1"]]
    }

    @Test func aClickRunsTheCloudPagesConfirmedOpsWithNoSheet() async throws {
        let presenter = Presenter(), recorder = Recorder()
        let native = cloud(presenter, recorder)
        let clicked = ["cmux.cloud.auth.sign_in", "cmux.cloud.auth.sign_out", "cmux.cloud.billing.open", "cmux.cloud.machine.connect",
                       "cmux.cloud.snapshot.restore"]
        for op in clicked {
            let answer = try await native.call(PageNativeOp.actionRun, params: run(op), context: clicks.next())
            #expect(answer["confirmed"]?.boolValue == true, "\(op)")
        }
        #expect(presenter.shown.isEmpty)
        #expect(recorder.calls.map { $0.op } == clicked)
        #expect(recorder.calls.allSatisfy { $0.context.isConfirmedUser })
    }

    @Test func noClickOrASpentClickStillAsks() async throws {
        let presenter = Presenter(), recorder = Recorder()
        let native = cloud(presenter, recorder)
        let once = clicks.next()
        _ = try await native.call(PageNativeOp.actionRun, params: run("cmux.cloud.auth.sign_in"), context: once)
        _ = try await native.call(PageNativeOp.actionRun, params: run("cmux.cloud.auth.sign_in"), context: once)
        _ = try await native.call(PageNativeOp.actionRun, params: run("cmux.cloud.auth.sign_in"),
                                  context: PageCallContext(page: PageDescriptor.cloud.id))
        #expect(presenter.shown.count == 2, "the same click again and page script alone ask")
        presenter.answer = false
        let declined = try await native.call(PageNativeOp.actionRun, params: run("cmux.cloud.auth.sign_out"),
                                             context: PageCallContext(page: PageDescriptor.cloud.id))
        #expect(declined["confirmed"]?.boolValue == false)
        #expect(recorder.calls.count == 3)
    }

    /// Publishing to the internet, firewall changes and every delete ask even
    /// after the click.
    @Test func publishFirewallAndDeletesAskEvenAfterAClick() async throws {
        let presenter = Presenter(), recorder = Recorder()
        let native = cloud(presenter, recorder)
        let asks = ["cmux.cloud.publication.create", "cmux.cloud.firewall.create", "cmux.cloud.firewall.delete",
                    "cmux.cloud.machine.delete", "cmux.cloud.snapshot.delete", "cmux.cloud.machine.archive_delete",
                    "cmux.cloud.publication.delete"]
        for op in asks {
            _ = try await native.call(PageNativeOp.actionRun, params: run(op), context: clicks.next())
        }
        #expect(presenter.shown.count == asks.count)
        #expect(Set(asks) == Set(PageDescriptor.cloud.confirmedOps.keys).subtracting(PageConfirmation.clickRunsOps))
        #expect(recorder.calls.count == asks.count && recorder.calls.allSatisfy { $0.context.isConfirmedUser })
    }

    @Test func codeRouterConnectGoesOnTheClick() async throws {
        let presenter = Presenter(), recorder = Recorder()
        let confirming = ConfirmingPageProvider(inner: recorder, presenter: presenter) { op, params in
            CodeRouterPageConfirmations.confirmation(op: op, params: params)
        }
        let connect: JSONValue = ["provider": "github"]
        _ = try await confirming.call(CodeRouterPageProvider.connectOp, params: connect,
                                      context: clicks.next(PageDescriptor.coderouter.id))
        #expect(presenter.shown.isEmpty)
        _ = try await confirming.call(CodeRouterPageProvider.connectOp, params: connect,
                                      context: PageCallContext(page: PageDescriptor.coderouter.id))
        #expect(presenter.shown.map(\.title) == [String(format: CodeRouterPageStrings.connectTitle, "github")])
        #expect(presenter.shown.first?.lines.isEmpty == true, "the title says it all")
        #expect(recorder.calls.count == 2 && recorder.calls.allSatisfy { $0.context.isConfirmedUser })
    }
}
