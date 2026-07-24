/// The app-provided configuration for the subrouter integration.
///
/// The app's composition root builds this from user settings and pushes a
/// new value into ``SubrouterStore/configuration`` whenever settings change;
/// the store reacts (going fully idle when disabled).
public struct SubrouterConfiguration: Sendable, Equatable {
    /// A disabled configuration (the default state before settings load).
    public static let disabled = SubrouterConfiguration(isEnabled: false)

    /// The master gate. When `false` the store cancels all work, clears its
    /// snapshot, and issues no network or subprocess activity at all.
    public var isEnabled: Bool
    /// The daemon address.
    public var endpoint: SubrouterEndpoint
    /// The `sr server` name the endpoint was resolved from, or `nil` when
    /// the endpoint is the local daemon or an explicit user override.
    public var serverName: String?
    /// An explicit path to the `sr`/`subrouter` binary, or `nil` to resolve
    /// from `PATH` and the standard install locations (`~/bin`, Homebrew).
    public var commandPath: String?
    /// Poll cadence and backoff tuning.
    public var tuning: SubrouterPollTuning

    /// Creates a configuration.
    /// - Parameters:
    ///   - isEnabled: The master gate.
    ///   - endpoint: The daemon address.
    ///   - commandPath: Explicit `sr` binary path, or `nil` to auto-resolve.
    ///   - tuning: Poll tuning.
    public init(
        isEnabled: Bool,
        endpoint: SubrouterEndpoint = .standard,
        serverName: String? = nil,
        commandPath: String? = nil,
        tuning: SubrouterPollTuning = .standard
    ) {
        self.isEnabled = isEnabled
        self.endpoint = endpoint
        self.serverName = serverName
        self.commandPath = commandPath
        self.tuning = tuning
    }

    /// Whether the daemon is a remote subrouter server rather than the local
    /// loopback daemon. Remote servers assign accounts per session on the
    /// server side, so global switching is unavailable.
    public var isRemoteEndpoint: Bool {
        guard let host = endpoint.baseURL.host()?.lowercased() else { return false }
        return host != "127.0.0.1" && host != "localhost" && host != "::1"
    }
}
