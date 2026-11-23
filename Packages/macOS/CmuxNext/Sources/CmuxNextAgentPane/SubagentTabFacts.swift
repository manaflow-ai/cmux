public import Foundation

/// What a subagent pane's tab says of the subagent it shows: its own state, since when and its
/// model, from its page (`chat.subagentShown`). The pane is a tab on its chat's session, so without
/// these its hover card and spinner read the chat's ("Working · 4m" for a subagent that finished).
public nonisolated struct SubagentTabFacts: Equatable, Sendable {
    public enum State: String, Sendable {
        case running, completed, failed, cancelled
    }

    public var state: State
    /// When the state began (its start while it runs, else its end), on this Mac's clock.
    public var since: Date?
    public var model: String?

    public init(state: State, since: Date? = nil, model: String? = nil) {
        self.state = state
        self.since = since
        self.model = model
    }

    /// The facts a `chat.subagentShown` request's params carry (`state`, `sinceMs`, `model`); nil
    /// without a known state. A `disconnected` subagent reads as stopped.
    init?(_ params: [String: Any]?) {
        let raw = params?["state"] as? String
        guard let state = raw == "disconnected" ? .cancelled : raw.flatMap(State.init(rawValue:)) else { return nil }
        self.state = state
        since = (params?["sinceMs"] as? Double).flatMap { $0 > 0 && $0.isFinite ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        model = (params?["model"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
    }
}
