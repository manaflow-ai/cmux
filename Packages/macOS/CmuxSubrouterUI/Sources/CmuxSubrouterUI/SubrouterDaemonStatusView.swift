public import SwiftUI
public import CmuxSubrouter

/// The daemon reachability header: healthy/unreachable state, the last
/// error, an install/start hint, and a retry action.
public struct SubrouterDaemonStatusView: View {
    private let state: SubrouterDaemonState
    private let lastErrorDescription: String?
    private let onRetry: () -> Void

    /// Creates the status header.
    /// - Parameters:
    ///   - state: The daemon reachability snapshot.
    ///   - lastErrorDescription: The last refresh failure, if any.
    ///   - onRetry: The manual-retry action.
    public init(
        state: SubrouterDaemonState,
        lastErrorDescription: String?,
        onRetry: @escaping () -> Void
    ) {
        self.state = state
        self.lastErrorDescription = lastErrorDescription
        self.onRetry = onRetry
    }

    public var body: some View {
        switch state {
        case .healthy:
            EmptyView()
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
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(
                        localized: "subrouter.daemon.unreachable",
                        defaultValue: "subrouter daemon unreachable"
                    ),
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
                Text(String(
                    localized: "subrouter.daemon.installHint",
                    defaultValue: "Install or start it with: ~/bin/subrouter install-daemon"
                ))
                .font(.system(size: 9).monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
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
    }
}
