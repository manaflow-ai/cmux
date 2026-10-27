import CmuxNextAgentActivity
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// Serves the Agent Activity page (``PageDescriptor/agentActivity``): `cmux.agentActivity.<method>`
/// runs the page's request (``AgentActivityRequests``), and `cmux.agentActivity.state` streams the
/// model's whole state, once at subscribe and then once per main-actor turn with changes.
@MainActor
final class AgentActivityPageProvider: PageProvider {
    /// The page's op prefix.
    nonisolated static let prefix = "cmux.agentActivity."
    /// The state stream.
    static let stateStream = "cmux.agentActivity.state"
    /// The page's requests (``AgentActivityRequests/reply(to:params:)``) and its stream. `perform`
    /// stops, pauses and resumes live computer-use sessions; the rest read or move the page's own view.
    nonisolated static let ops = PageOpTable(namespace: prefix,
                                             read: ["ready", "select", "filter", "scrub", "layout", "follow", "frame", "state"],
                                             act: ["perform"])

    private let requests: AgentActivityRequests
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    /// Coalesces bursts of model changes into one state event per posted task.
    private var pushScheduled = false
    /// The app's main-thread scheduler: each coalesced push is one `visible` task on it.
    private let mainWork: MainWorkScheduler

    init(requests: AgentActivityRequests, mainWork: MainWorkScheduler) {
        self.requests = requests
        self.mainWork = mainWork
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
        // Each event carries the model's whole state: the newest replaces the rest.
        return PageSubscription(frozenDelivery: .latest) { [weak self] in self?.listeners[id] = nil }
    }

    private func schedulePush() {
        guard !pushScheduled else { return }
        pushScheduled = true
        // `visible`: the page redraws what the model changed, which no input of the person in this turn caused.
        // node-free: the page host keeps only a hidden page's newest state (`frozenDelivery: .latest`), so the push runs.
        mainWork.post(.visible, owner: "AgentActivityPageProvider.push") { [weak self] in
            guard let self else { return }
            pushScheduled = false
            let state = Self.json(requests.state())
            for listener in listeners.values { listener(state) }
        }
    }

    /// The request types' Foundation graph (with `nil` optionals) as JSON: through
    /// `JSONSerialization`, which writes a missing optional as null.
    static func json(_ value: Any) -> JSONValue {
        guard let data = try? CheckedJSON().data(["v": value]),
              case .object(let members)? = try? JSONValue.parse(data) else { return .null }
        return members["v"] ?? .null
    }
}
