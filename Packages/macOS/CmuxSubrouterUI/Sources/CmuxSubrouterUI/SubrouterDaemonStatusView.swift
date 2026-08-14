public import SwiftUI
public import CmuxSubrouter

/// The daemon reachability header.
///
/// Two very different situations share the `unreachable` state and must
/// not share a treatment:
/// - **No data at all** (daemon never answered): a prominent card with the
///   local install hint (loopback only) and a Retry button.
/// - **Live data on screen** (a refresh started failing): a single quiet
///   "reconnecting" line — the accounts below are still perfectly useful,
///   so no card, no install hint, no alarm.
public struct SubrouterDaemonStatusView: View {
    private let state: SubrouterDaemonState
    private let lastErrorDescription: String?
    /// Whether the panel has account data to stand on.
    private let hasData: Bool
    /// Whether the endpoint is a remote server (hides the local install
    /// hint and names the server instead).
    private let isRemoteEndpoint: Bool
    /// The remote server's display name, when known.
    private let serverName: String?
    private let onRetry: () -> Void
    /// Opens a terminal running `cmux subrouter setup`, or `nil` when the
    /// host cannot open terminals (previews, tests, remote endpoints).
    private let onSetup: (() -> Void)?
    /// Opens a terminal with the connect-to-hosted-server command
    /// pre-typed, or `nil` when the host cannot open terminals or the
    /// endpoint is already remote.
    private let onConnectServer: (() -> Void)?

    /// Creates the status header.
    /// - Parameters:
    ///   - state: The daemon reachability snapshot.
    ///   - lastErrorDescription: The last refresh failure, if any.
    ///   - hasData: Whether account data is currently rendered below.
    ///   - isRemoteEndpoint: Whether the endpoint is a remote server.
    ///   - serverName: The remote server's name, when known.
    ///   - onRetry: The manual-retry action.
    ///   - onSetup: Opens a terminal running the first-run setup, shown as
    ///     the primary action when the local daemon is unreachable.
    ///   - onConnectServer: Opens a terminal with the hosted-server
    ///     connect command pre-typed, shown as the secondary path.
    public init(
        state: SubrouterDaemonState,
        lastErrorDescription: String?,
        hasData: Bool = false,
        isRemoteEndpoint: Bool = false,
        serverName: String? = nil,
        onRetry: @escaping () -> Void,
        onSetup: (() -> Void)? = nil,
        onConnectServer: (() -> Void)? = nil
    ) {
        self.state = state
        self.lastErrorDescription = lastErrorDescription
        self.hasData = hasData
        self.isRemoteEndpoint = isRemoteEndpoint
        self.serverName = serverName
        self.onRetry = onRetry
        self.onSetup = onSetup
        self.onConnectServer = onConnectServer
    }

    public var body: some View {
        switch state {
        case .healthy:
            // The daemon answers its health probe but the last data fetch
            // failed (provider fan-out timeout, transient 5xx): what is on
            // screen may be stale, so say so quietly instead of presenting
            // old quotas as live.
            if let lastErrorDescription, !lastErrorDescription.isEmpty {
                staleDataLine(description: lastErrorDescription)
            }
        case .unknown:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                Text(String(
                    localized: "subrouter.daemon.connecting",
                    defaultValue: "Contacting subrouter daemon…"
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        case .unreachable:
            if hasData {
                reconnectingLine
            } else {
                unreachableCard
            }
        }
    }

    /// The healthy-daemon warning: the daemon is up but data refreshes are
    /// failing, so the rendered accounts/quotas may be stale. One dim line
    /// with an inline retry; the failure detail lives in the tooltip.
    private func staleDataLine(description: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 8))
            Text(String(
                localized: "subrouter.daemon.refreshFailed",
                defaultValue: "Refresh failing — data may be stale"
            ))
            .font(.system(size: 9))
            Button(action: onRetry) {
                Text(String(localized: "subrouter.daemon.retry", defaultValue: "Retry"))
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .foregroundStyle(.secondary)
        .help(description)
    }

    /// The quiet variant: data is on screen, so a refresh hiccup is one
    /// dim line with an inline retry, not a banner.
    private var reconnectingLine: some View {
        HStack(spacing: 5) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 8))
            Text(String(
                localized: "subrouter.daemon.reconnecting",
                defaultValue: "Connection lost — showing last data"
            ))
            .font(.system(size: 9))
            Button(action: onRetry) {
                Text(String(localized: "subrouter.daemon.retry", defaultValue: "Retry"))
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .foregroundStyle(.secondary)
        .help(lastErrorDescription ?? "")
    }

    @ViewBuilder
    private var unreachableCard: some View {
        if isRemoteEndpoint {
            remoteUnreachableCard
        } else {
            localOnboardingCard
        }
    }

    /// The first-run onboarding card for the local daemon: not an error
    /// (nothing the user set up has broken), so it presents calmly and
    /// names both hosting choices, with local as the default path. Also
    /// what a user with a stopped daemon sees — Set up restarts it.
    private var localOnboardingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(String(
                    localized: "subrouter.daemon.onboardingTitle",
                    defaultValue: "Set up Subrouter"
                ))
            } icon: {
                Text("🍣")
            }
            .font(.system(size: 11, weight: .semibold))
            Text(String(
                localized: "subrouter.daemon.onboardingBody",
                defaultValue: "Pool multiple agent accounts and route each session automatically. Run it on this Mac (default), or connect to a hosted server."
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            // One click opens a terminal that installs the sr CLI (when
            // missing), starts the daemon, and prints how to add accounts.
            // Hosts without a terminal (previews) fall back to the
            // copyable command hint.
            if onSetup == nil {
                Text(String(
                    localized: "subrouter.daemon.installHint",
                    defaultValue: "Install or start it with: cmux subrouter setup"
                ))
                .font(.system(size: 9).monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                if let onSetup {
                    Button(action: onSetup) {
                        Text(String(
                            localized: "subrouter.daemon.setup",
                            defaultValue: "Set up subrouter"
                        ))
                        .font(.system(size: 10))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                if let onConnectServer {
                    Button(action: onConnectServer) {
                        Text(String(
                            localized: "subrouter.daemon.connectServer",
                            defaultValue: "Use a server…"
                        ))
                        .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                Button(action: onRetry) {
                    Text(String(localized: "subrouter.daemon.retry", defaultValue: "Retry"))
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.top, 2)
            if let lastErrorDescription, !lastErrorDescription.isEmpty {
                Text(lastErrorDescription)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The genuine-failure card: a server the user configured is not
    /// answering, which deserves the alarm treatment.
    private var remoteUnreachableCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                remoteUnreachableTitle,
                systemImage: "bolt.horizontal.circle"
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.orange)
            if let lastErrorDescription, !lastErrorDescription.isEmpty {
                Text(lastErrorDescription)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Button(action: onRetry) {
                Text(String(localized: "subrouter.daemon.retry", defaultValue: "Retry"))
                    .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var remoteUnreachableTitle: String {
        let name = serverName ?? ""
        return String(
            localized: "subrouter.daemon.serverUnreachable",
            defaultValue: "Can't reach server \(name)"
        )
    }
}
