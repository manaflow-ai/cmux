import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// Why nothing can change: the supervisor is unreachable. Every control
/// below is disabled; nothing queues. While cmux-tui itself cannot be reached
/// the banner carries the App's recovery controls (Retry Now, Restart cmux-tui).
struct AppsDisconnectedBanner: View {
    let reason: AppsUnavailableReason
    var recovery: AppsRecovery?
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        HStack(spacing: Metrics.space2) {
            Icon(.statusDisconnected, size: 13)
            Text(AppsStrings.unavailable(reason)).font(Font(Typography.bodyEmphasized))
            Text(AppsStrings.unavailableHelp).font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
            Spacer()
            if let recovery {
                if let status = recovery.status {
                    Text(status).font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
                }
                ForEach(recovery.actions) { action in
                    Button(action.title) { action.run() }
                        .controlSize(.small)
                        .disabled(!action.isEnabled)
                        .accessibilityIdentifier("appStore.disconnected.\(action.id)")
                }
            }
        }
        .foregroundStyle(colors.secondary)
        .padding(.horizontal, Metrics.space5)
        .padding(.vertical, Metrics.space2)
        .background(colors.hover)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appStore.disconnected")
    }
}

/// The App's controls on the disconnected banner while cmux-tui cannot be
/// reached (``AppStoreModel/recovery``), and what a restart shows.
public nonisolated struct AppsRecovery {
    public var actions: [AppsRecoveryAction]
    public var status: String?

    public init(actions: [AppsRecoveryAction], status: String?) {
        self.actions = actions
        self.status = status
    }
}

/// One control on the disconnected banner.
public nonisolated struct AppsRecoveryAction: Identifiable {
    public let id: String
    public let title: String
    public let isEnabled: Bool
    public let run: @MainActor () -> Void

    public init(id: String, title: String, isEnabled: Bool, run: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.run = run
    }
}
