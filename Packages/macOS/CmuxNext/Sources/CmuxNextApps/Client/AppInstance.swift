public import Foundation

/// A running deployment of an app's server (`inst_…`, docs/app-store-platonic-ideal.md 8): the
/// supervisor's `instance` on an `apps-list` row. The daemon owns it; the client only shows it
/// and opens its URL in the app's remote pane.
public nonisolated struct AppInstance: Sendable, Hashable {
    /// The instance's lifecycle as the supervisor reports it.
    public enum State: String, Sendable, Hashable {
        /// The runner is starting the container and waiting for its health check.
        case deploying
        /// Healthy; ``AppInstance/url`` opens it.
        case running
    }

    /// The instance id (`inst_…`).
    public var id: String
    /// Where it runs: `self-hosted:<host>` or `cloud-vm:<machine>`.
    public var target: String
    public var state: State
    /// The instance's URL once it runs (its tailnet or loopback address), else nil.
    public var url: URL?

    /// Creates an instance value (tests and the fake transport).
    /// - Parameters:
    ///   - id: The instance id.
    ///   - target: Where it runs.
    ///   - state: Its lifecycle state.
    ///   - url: Its URL once running.
    public init(id: String, target: String, state: State, url: URL?) {
        self.id = id
        self.target = target
        self.state = state
        self.url = url
    }

    /// Decodes the supervisor's `instance` object; nil for null or a malformed value.
    /// - Parameter json: The `instance` member of an `apps-list` row.
    public init?(json: AppJSON?) {
        guard let json, let id = json["id"]?.stringValue, let target = json["target"]?.stringValue,
              let state = json["state"]?.stringValue.flatMap(State.init(rawValue:)) else { return nil }
        self.init(id: id, target: target, state: state, url: json["url"]?.stringValue.flatMap(URL.init(string:)))
    }
}
