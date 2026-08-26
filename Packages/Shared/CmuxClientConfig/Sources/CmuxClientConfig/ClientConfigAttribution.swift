/// Low-cardinality request labels for `/api/client-config`.
///
/// The web route logs one structured line per request from these `X-Cmux-*`
/// headers, which is the only per-client request-volume counter we have:
/// PostHog billing reports a single project-wide daily total with no client,
/// version, or channel breakdown. Labels ride in headers, not the request
/// body, so the route can attribute rate-limited requests it never parses and
/// the body keeps its telemetry-consent contract. Every value is a fleet-wide
/// label; none identifies a user or install.
public struct ClientConfigAttribution: Sendable, Equatable {
    /// Why a control-plane refresh fired, separating launch bursts from
    /// steady-state polling in server logs.
    public enum RefreshReason: String, Sendable {
        case launch
        case timer
        case foreground
        case manual
    }

    /// The requesting app, e.g. `ios`.
    public var client: String
    /// The release channel, e.g. `stable`, `nightly`, or `dev`.
    public var channel: String
    /// The marketing version (`CFBundleShortVersionString`), if stamped.
    public var appVersion: String?
    /// The build number (`CFBundleVersion`), if stamped.
    public var appBuild: String?
    /// The trigger for this specific request.
    public var refreshReason: RefreshReason?
    /// The steady-state poll cadence the client is configured with.
    public var pollIntervalSeconds: Int?

    public init(
        client: String,
        channel: String,
        appVersion: String? = nil,
        appBuild: String? = nil,
        refreshReason: RefreshReason? = nil,
        pollIntervalSeconds: Int? = nil
    ) {
        self.client = client
        self.channel = channel
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.refreshReason = refreshReason
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    /// The header fields the loader attaches to the HTTP request. Names match
    /// `web/services/client-config/requestAttribution.ts`.
    public var headerFields: [String: String] {
        var fields = [
            "X-Cmux-Client": client,
            "X-Cmux-Channel": channel,
        ]
        if let appVersion, !appVersion.isEmpty {
            fields["X-Cmux-App-Version"] = appVersion
        }
        if let appBuild, !appBuild.isEmpty {
            fields["X-Cmux-App-Build"] = appBuild
        }
        if let refreshReason {
            fields["X-Cmux-Refresh-Reason"] = refreshReason.rawValue
        }
        if let pollIntervalSeconds {
            fields["X-Cmux-Poll-Interval"] = String(pollIntervalSeconds)
        }
        return fields
    }
}
