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

    /// Creates the status header.
    /// - Parameters:
    ///   - state: The daemon reachability snapshot.
    ///   - lastErrorDescription: The last refresh failure, if any.
    ///   - hasData: Whether account data is currently rendered below.
    ///   - isRemoteEndpoint: Whether the endpoint is a remote server.
    ///   - serverName: The remote server's name, when known.
    ///   - onRetry: The manual-retry action.
    public init(
        state: SubrouterDaemonState,
        lastErrorDescription: String?,
        hasData: Bool = false,
        isRemoteEndpoint: Bool = false,
        serverName: String? = nil,
        onRetry: @escaping () -> Void
    ) {
        self.state = state
        self.lastErrorDescription = lastErrorDescription
        self.hasData = hasData
        self.isRemoteEndpoint = isRemoteEndpoint
        self.serverName = serverName
        self.onRetry = onRetry
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

    private var unreachableCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                unreachableTitle,
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
            // The install hint only makes sense for the local daemon; a
            // remote server is installed and managed on its own machine.
            if !isRemoteEndpoint {
                Text(String(
                    localized: "subrouter.daemon.installHint",
                    defaultValue: "Install or start it with: ~/bin/subrouter install-daemon"
                ))
                .font(.system(size: 9).monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
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

    private var unreachableTitle: String {
        if isRemoteEndpoint {
            let name = serverName ?? ""
            return String(
                localized: "subrouter.daemon.serverUnreachable",
                defaultValue: "Can't reach server \(name)"
            )
        }
        return String(
            localized: "subrouter.daemon.unreachable",
            defaultValue: "subrouter daemon unreachable"
        )
    }
}
