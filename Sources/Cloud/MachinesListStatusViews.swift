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

        /// The toolbar has one line beside the status text, so it takes the
        /// verb alone. The notice and the empty state keep the full `title`.
        var shortTitle: String {
            switch self {
            case .retry:
                // Already one word.
                return title
            case .signInAgain:
                return String(localized: "machines.sessionRejected.signInAgain.short", defaultValue: "Sign In")
            case .upgrade:
                return String(localized: "machines.requiresPro.upgrade.short", defaultValue: "Upgrade")
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
    /// The one-line form for the toolbar, where cached machines are still on
    /// screen. It names the same cause as `title`, so a 401 and a 402 do not
    /// both read "unavailable" with no way to act. nil keeps the plain title.
    let staleTitle: String?

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
            staleTitle = String(localized: "machines.offline.stale", defaultValue: "Offline — showing last known")
        case .reconnecting:
            symbolName = nil
            title = String(localized: "machines.reconnecting.title", defaultValue: "Reconnecting to Cloud…")
            subtitle = nil
            action = nil
            isFailure = false
            staleTitle = nil
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
            staleTitle = String(localized: "machines.listUnavailable.stale", defaultValue: "Machine list unavailable — showing last known")
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
            staleTitle = String(localized: "machines.sessionRejected.stale", defaultValue: "Sign-in needs a refresh — showing last known")
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
            staleTitle = String(localized: "machines.requiresPro.stale", defaultValue: "Cloud machines need cmux Pro — showing last known")
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
        .padding(.horizontal, RightSidebarChromeMetrics.barHorizontalPadding)
        .padding(.vertical, RightSidebarChromeMetrics.barVerticalPadding)
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
                .cloudProminentButtonStyle()
                .controlSize(.small)
        }
    }
}

/// The toolbar's one-line status while cached machines stay on screen.
struct MachinesListStatusToolbarRow: View {
    let status: MachineListStatus
    /// Stable dismissal identity only; upstream details are never presented.
    let dismissalSignature: String?
    let onDismiss: (String) -> Void
    let perform: (MachineListStatusPresentation.Action) -> Void

    /// Safe next steps shared by hover help and Copy Error.
    var errorMessage: String? {
        let presentation = MachineListStatusPresentation(status)
        return presentation.isFailure ? (presentation.subtitle ?? presentation.title) : nil
    }

    var body: some View {
        let presentation = MachineListStatusPresentation(status)
        // Only a failure is orange, carries safe recovery copy on hover, and
        // can be dismissed. Upstream response details stay out of the view.
        let failure = presentation.isFailure ? dismissalSignature : nil
        let row = HStack(spacing: 5) {
            if let symbolName = presentation.symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 10, weight: .semibold))
            } else {
                ProgressView().controlSize(.mini)
            }
            label(presentation.staleTitle ?? presentation.title)
            if let action = presentation.action {
                Button(action.shortTitle) { perform(action) }
                    .buttonStyle(.link)
                    .cmuxFont(size: 11)
                    // The sidebar gets narrow. Truncating the status line is
                    // survivable, losing the only affordance that fixes the
                    // failure is not, so the verb keeps its width.
                    .fixedSize()
                    .accessibilityIdentifier(action.accessibilityIdentifier)
            }
        }
        .foregroundColor(presentation.isFailure ? .orange.opacity(0.9) : .secondary)
        // Hover text and the copy menu belong to a failure only.
        // `cloudErrorCopyMenu(nil)` attaches an empty `.contextMenu {}`, which
        // suppresses whatever menu the header would otherwise inherit, so it
        // must not run for waiting or reconnecting.
        if let failure {
            row
                .help(errorMessage ?? presentation.title)
                .cloudErrorCopyMenu(errorMessage)
            CloudBannerDismissButton { onDismiss(failure) }
        } else {
            row
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .cmuxFont(size: 11)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
