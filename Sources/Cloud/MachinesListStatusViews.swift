import CmuxCloud
import SwiftUI

/// Symbol, copy and action for one ``MachineListStatus``. The compact notice,
/// the empty state and the toolbar row all read it, so they never disagree.
struct MachineListStatusPresentation {
    enum Action: Equatable {
        case retry
        case signInAgain
        case upgrade

        var title: String {
            switch self {
            case .retry:
                return String(localized: "machines.unavailable.retry", defaultValue: "Retry")
            case .signInAgain:
                return String(localized: "machines.sessionRejected.signInAgain", defaultValue: "Sign Out & Sign In Again")
            case .upgrade:
                return String(localized: "machines.requiresPro.upgrade", defaultValue: "Upgrade to Pro")
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .retry: return "CloudMachinesUnavailableRetryButton"
            case .signInAgain: return "CloudMachinesSessionRejectedSignInButton"
            case .upgrade: return "CloudMachinesRequiresProUpgradeButton"
            }
        }
    }

    /// `nil` draws a spinner: a read is in progress.
    let symbolName: String?
    let title: String
    let subtitle: String?
    let action: Action?
    /// Failures tint orange; waiting and reconnecting stay neutral.
    let isFailure: Bool

    init(_ status: MachineListStatus) {
        switch status {
        case .waitingForNetwork:
            // The coordinator restarts the read when the network returns; a
            // Retry here could only fail again.
            symbolName = "wifi.slash"
            title = String(localized: "machines.offline.title", defaultValue: "Waiting for network")
            subtitle = String(localized: "machines.offline.subtitle", defaultValue: "Cloud machines load when this Mac is back online.")
            action = nil
            isFailure = false
        case .reconnecting:
            symbolName = nil
            title = String(localized: "machines.reconnecting.title", defaultValue: "Reconnecting to Cloud…")
            subtitle = nil
            action = nil
            isFailure = false
        case .failed(.unreachable):
            // Only the machine-list read failed: say that, not "Cloud is down".
            symbolName = "exclamationmark.icloud"
            title = String(localized: "machines.listUnavailable.title", defaultValue: "Can’t load the machine list")
            subtitle = String(
                localized: "machines.listUnavailable.subtitle",
                defaultValue: "Your machines are unchanged. cmux couldn’t load the list from the Cloud service and retries on its own."
            )
            action = .retry
            isFailure = true
        case .failed(.sessionRejected):
            // HTTP 401: retrying can never fix it, so route to a fresh sign-in.
            symbolName = "person.crop.circle.badge.exclamationmark"
            title = String(localized: "machines.sessionRejected.title", defaultValue: "Sign-in needs a refresh")
            subtitle = String(
                localized: "machines.sessionRejected.subtitle",
                defaultValue: "The Cloud service no longer accepts this Mac’s saved session. Sign out and sign back in to reconnect."
            )
            action = .signInAgain
            isFailure = true
        case .failed(.requiresPro):
            // HTTP 402: the fix is an upgrade, not a retry and not a sign-in.
            symbolName = "sparkles"
            title = String(localized: "machines.requiresPro.title", defaultValue: "Cloud machines need cmux Pro")
            subtitle = String(
                localized: "machines.requiresPro.subtitle",
                defaultValue: "This account’s plan doesn’t include Cloud machine access. Upgrade to create and reconnect machines."
            )
            action = .upgrade
            isFailure = true
        }
    }
}

/// One line above a list that still has rows (This Mac, devices) but no Cloud machines.
struct MachinesListStatusNotice: View {
    let status: MachineListStatus
    let perform: (MachineListStatusPresentation.Action) -> Void

    var body: some View {
        let presentation = MachineListStatusPresentation(status)
        HStack(spacing: 6) {
            if let symbolName = presentation.symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 11, weight: .semibold))
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(presentation.title)
                .cmuxFont(size: 11)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let action = presentation.action {
                Button(action.title) { perform(action) }
                    .buttonStyle(.link)
                    .cmuxFont(size: 11)
                    .accessibilityIdentifier(action.accessibilityIdentifier)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(presentation.isFailure ? Color.orange.opacity(0.08) : Color.secondary.opacity(0.06))
        .accessibilityIdentifier("CloudMachinesUnavailableNotice")
    }
}

/// The empty panel's account of the machine-list read, in place of "No machines yet".
struct MachinesListStatusEmptyState: View {
    let status: MachineListStatus
    let perform: (MachineListStatusPresentation.Action) -> Void

    var body: some View {
        let presentation = MachineListStatusPresentation(status)
        VStack(spacing: 10) {
            if let symbolName = presentation.symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(.secondary.opacity(0.55))
            } else {
                ProgressView().controlSize(.small)
            }
            Text(presentation.title)
                .cmuxFont(size: 13, weight: .semibold)
                .foregroundColor(.primary.opacity(0.85))
            if let subtitle = presentation.subtitle {
                Text(subtitle)
                    .cmuxFont(size: 12)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            if let action = presentation.action {
                actionButton(action)
                    .padding(.top, 2)
                    .accessibilityIdentifier(action.accessibilityIdentifier)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: MachineListStatusPresentation.Action) -> some View {
        let button = Button {
            perform(action)
        } label: {
            Text(action.title)
                .cmuxFont(size: 12)
        }
        if action == .retry {
            button
        } else {
            button
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

/// The toolbar's one-line status while cached machines stay on screen.
struct MachinesListStatusToolbarRow: View {
    let status: MachineListStatus
    let error: String?
    let onDismiss: (String) -> Void

    var body: some View {
        switch status {
        case .reconnecting:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                label(MachineListStatusPresentation(status).title)
            }
            .foregroundColor(.secondary)
        case .waitingForNetwork:
            HStack(spacing: 5) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 10, weight: .semibold))
                label(String(localized: "machines.offline.stale", defaultValue: "Offline \u{2014} showing last known"))
            }
            .foregroundColor(.secondary)
        case .failed:
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .semibold))
                label(String(localized: "machines.listUnavailable.stale", defaultValue: "Machine list unavailable \u{2014} showing last known"))
            }
            .foregroundColor(.orange.opacity(0.9))
            .help(error ?? "")
            .cloudErrorCopyMenu(error)
            if let error {
                CloudBannerDismissButton { onDismiss(error) }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .cmuxFont(size: 11)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
