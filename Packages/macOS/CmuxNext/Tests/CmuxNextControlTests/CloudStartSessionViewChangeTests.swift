import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// Leo: "you guys kept fighting focus". `cmux cloud start-session` from the CLI (an agent's or a probe's
/// start, `cloud start-chat`'s step) may change the app's view only when it says `--focus`: the run's
/// invocation and its scope (``ActionRunScope``, which every show, select, claim and key-window change
/// asks) both say no for today's run and for `--no-focus` (`focus: false`), so the start shows, selects
/// and raises nothing (`CloudStartSession`'s reveal asks `invocation.allowsViewChange`). A person's own
/// start in the app (origin `user`) still reveals its chat and takes focus.
@MainActor
@Suite struct CloudStartSessionViewChangeTests {
    struct Seen: Equatable {
        var allows: Bool
        var scope: Bool
    }

    /// What the start's handler sees for each socket request, sent as the Rust CLI sends it.
    @Test func aCLIStartChangesTheViewOnlyWithFocus() async {
        let registry = ActionRegistry.standard()
        var seen: [Seen] = []
        registry.bind("cloudStartSession", invoke: { invocation in
            seen.append(Seen(allows: invocation.allowsViewChange, scope: ActionRunScope.viewChangeAllowed()))
        })
        let router = ControlRouter(identity: testIdentity(), executor: RegistryControlBridge(registry: registry), settings: nil,
                                   configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        let args: JSONValue = .object(["name": .string("box"), "agent": .string("claude")])
        let socket = ControlConnectionID(rawValue: 1) // a `cmux` run on the control socket, never in-process
        // `--no-focus`, today's run (no focus at all), then `--focus`.
        for focus: JSONValue? in [.bool(false), nil, .bool(true)] {
            var params: [String: JSONValue] = ["action": "cloud start-session", "cli": .bool(true), "origin": "script", "args": args]
            if let focus { params["focus"] = focus }
            if case .failure(let error) = await router.handle(ControlRequest(id: "1", method: "action.run", params: params), connection: socket) {
                Issue.record("\(String(describing: focus)): \(error.message)")
            }
        }
        #expect(seen == [Seen(allows: false, scope: false), Seen(allows: false, scope: false), Seen(allows: true, scope: true)])
        // The socket never acts as the person in the app: a CLI run cannot claim origin `user` to reveal.
        let claimed = await router.handle(ControlRequest(id: "2", method: "action.run", params: [
            "action": "cloud start-session", "cli": .bool(true), "origin": "user", "args": args,
        ]), connection: socket)
        if case .success = claimed { Issue.record("a socket run claimed the person's origin") }
        #expect(seen.count == 3)
    }

    /// A person's start in the app (the palette, a menu, the composer's Cloud start) keeps revealing its chat.
    @Test func aPersonsStartInTheAppRevealsItsChat() {
        let registry = ActionRegistry.standard()
        var seen: Seen?
        registry.bind("cloudStartSession", invoke: { invocation in
            seen = Seen(allows: invocation.allowsViewChange, scope: ActionRunScope.viewChangeAllowed())
        })
        #expect(registry.perform("cloudStartSession", invocation: ActionInvocation(origin: .user)))
        #expect(seen == Seen(allows: true, scope: true))
    }
}
