import CmuxNextAgentActivity
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Serves the Agent Activity page (``PageDescriptor/agentActivity``): `cmux.agentActivity.<method>`
/// runs the page's request (``AgentActivityRequests``), and `cmux.agentActivity.state` streams the
/// model's whole state, once at subscribe and then once per main-actor turn with changes.
@MainActor
final class AgentActivityPageProvider: PageProvider {
    /// The page's op prefix.
    static let prefix = "cmux.agentActivity."
    /// The state stream.
    static let stateStream = "cmux.agentActivity.state"

    private let requests: AgentActivityRequests
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    /// Coalesces bursts of model changes into one state event per main-actor turn.
    private var pushScheduled = false

    init(requests: AgentActivityRequests) {
        self.requests = requests
        requests.model.onChange = { [weak self] in self?.schedulePush() }
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op.hasPrefix(Self.prefix) else { throw PageError.unknownOp(op) }
        let method = String(op.dropFirst(Self.prefix.count))
        let reply = await requests.reply(to: method, params: params.foundationObject as? [String: Any] ?? [:])
        guard reply["ok"] as? Bool == true else {
            let message = (reply["error"] as? [String: Any])?["userMessage"] as? String ?? method
            throw PageError(code: "cmux.agentActivity.failed", message: message)
        }
        return Self.json(reply["value"] ?? NSNull())
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.stateStream else { throw PageError.unknownOp(stream) }
        let id = UUID()
        listeners[id] = onEvent
        onEvent(Self.json(requests.state()))
        return PageSubscription { [weak self] in self?.listeners[id] = nil }
    }

    private func schedulePush() {
        guard !pushScheduled else { return }
        pushScheduled = true
        // task-owner: one coalesced state event per main-actor turn; ends at once
        Task { [weak self] in
            guard let self else { return }
            pushScheduled = false
            let state = Self.json(requests.state())
            for listener in listeners.values { listener(state) }
        }
    }

    /// The request types' Foundation graph (with `nil` optionals) as JSON: through
    /// `JSONSerialization`, which writes a missing optional as null.
    static func json(_ value: Any) -> JSONValue {
        guard let data = try? JSONSerialization.data(withJSONObject: ["v": value]),
              case .object(let members)? = try? JSONValue.parse(data) else { return .null }
        return members["v"] ?? .null
    }
}
