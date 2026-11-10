public import CmuxNextPages
public import CmuxNextSettings
import CmuxNextCompat
import Foundation

/// The Set Up cmux card on the React Messages page (cmux#37736 round 9 F1): the page draws
/// home-messages/cards/setup/SetupCard over a Chief's chat as the native Home hosted it (CmuxNextApp
/// HomeHostView+SetupCard: #39240, #39270, #39388), and this serves it under the page's own prefix.
/// - `shows` (stream and call) -> `{shows}`: whether ``FirstRunSetup`` shows the card (a first run, until Hide or
///   every row done); sent on subscribe and on every change.
/// - `state`, `run`, `hide`, `focused` and the `changed` stream: ``SetupCardPageProvider``'s `cmux.setup.*`, the
///   same rows, actions, gesture rule and dismissal. Its provider is made only while the card shows (as the native
///   host made its card), and goes with it.
@MainActor
public final class SetupCardRoute: PageProvider {
    public nonisolated static let prefix = HomeMessagesPageRoute.prefix + "setup."
    /// The ops ``SetupCardPageProvider`` answers, by their name under ``prefix``.
    static let forwarded: Set<String> = ["state", "run", "hide", "focused", "changed"]

    private let setup: FirstRunSetup
    private let agents: @MainActor () -> (any AgentSignInSource)?
    private let environment: SetupCardEnvironment
    private(set) var provider: SetupCardPageProvider?

    /// `agents` is read when the card's provider is made (the native host read it on show).
    public init(setup: FirstRunSetup, agents: @escaping @MainActor () -> (any AgentSignInSource)?, environment: SetupCardEnvironment) {
        self.setup = setup
        self.agents = agents
        self.environment = environment
    }

    /// The card's provider while the card shows (made on first use); none, and the last one stopped, once it ends.
    func current() -> SetupCardPageProvider? {
        guard setup.shows else {
            provider?.stop()
            provider = nil
            return nil
        }
        if let provider { return provider }
        let made = SetupCardPageProvider(setup: setup, agents: agents(), environment: environment)
        provider = made
        return made
    }

    private func name(_ op: String) -> String {
        op.hasPrefix(Self.prefix) ? String(op.dropFirst(Self.prefix.count)) : op
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let name = name(op)
        if name == "shows" { return ["shows": .bool(setup.shows)] }
        guard Self.forwarded.contains(name) else { throw PageError.unknownOp(op) }
        guard let provider = current() else { throw PageError.unavailable("the Set Up cmux card is not showing") }
        return try await provider.call(SetupCardPageProvider.prefix + name, params: params, context: context)
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        switch name(stream) {
        case "shows":
            let setup = setup
            // task-owner: one per page subscription; its PageSubscription cancels it. Event-driven (Observation).
            let task = Task { [weak self] in
                for await shows in ObservationStream({ setup.shows }) {
                    guard !Task.isCancelled else { return }
                    if !shows { _ = self?.current() }
                    onEvent(["shows": .bool(shows)])
                }
            }
            return PageSubscription { task.cancel() }
        case "changed":
            guard let provider = current() else { throw PageError.unavailable("the Set Up cmux card is not showing") }
            return try await provider.subscribe(SetupCardPageProvider.prefix + "changed", filter: filter, context: context, onEvent: onEvent)
        default:
            throw PageError.unknownOp(stream)
        }
    }
}
