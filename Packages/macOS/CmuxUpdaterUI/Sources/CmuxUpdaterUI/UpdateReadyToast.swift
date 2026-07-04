import CmuxFoundation
public import SwiftUI
public import CmuxUpdater
import AppKit

/// A transient toast shown in the sidebar when an update has been downloaded and staged in the
/// background: one click on "Restart" finishes the install.
///
/// Visibility is derived entirely from ``UpdateStateModel/updateReadyToastInstalling``
/// (staged auto-update present, not dismissed for this version, not muted, restart-when-idle
/// not armed). Sized to fill the sidebar width, so the actions stack vertically.
public struct UpdateReadyToast: View {
    private let model: UpdateStateModel
    private let actions: any UpdateActionsHost
    @Environment(\.openURL) private var openURL

    /// Creates the toast bound to the observable update state.
    public init(model: UpdateStateModel, actions: any UpdateActionsHost) {
        self.model = model
        self.actions = actions
    }

    /// The mute choices offered by the bell menu.
    private static let muteOptions: [(label: String, accessibilityIdentifier: String, duration: TimeInterval)] = [
        (String(localized: "update.toast.mute.oneHour", defaultValue: "For 1 Hour"), "UpdateReadyToastMuteOneHour", 60 * 60),
        (String(localized: "update.toast.mute.eightHours", defaultValue: "For 8 Hours"), "UpdateReadyToastMuteEightHours", 8 * 60 * 60),
        (String(localized: "update.toast.mute.oneDay", defaultValue: "For 1 Day"), "UpdateReadyToastMuteOneDay", 24 * 60 * 60),
        (String(localized: "update.toast.mute.threeDays", defaultValue: "For 3 Days"), "UpdateReadyToastMuteThreeDays", 3 * 24 * 60 * 60),
        (String(localized: "update.toast.mute.oneWeek", defaultValue: "For 1 Week"), "UpdateReadyToastMuteOneWeek", 7 * 24 * 60 * 60),
    ]

    /// The toast body, visible only while the model exposes a staged automatic update.
    public var body: some View {
        ZStack {
            if let installing = model.updateReadyToastInstalling {
                toastCard(installing)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.updateReadyToastInstalling != nil)
    }

    @ViewBuilder
    private func toastCard(_ installing: UpdateState.Installing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill")
                    .cmuxFont(size: 11)
                    .foregroundStyle(.tint)

                Text(title(for: installing))
                    .cmuxFont(size: 12, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                Menu {
                    ForEach(Self.muteOptions, id: \.duration) { option in
                        Button(option.label) {
                            model.muteUpdateReadyToast(for: option.duration)
                        }
                        .accessibilityIdentifier(option.accessibilityIdentifier)
                    }
                } label: {
                    Image(systemName: "bell.slash")
                        .cmuxFont(size: 10)
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .safeHelp(String(localized: "update.toast.mute", defaultValue: "Mute"))
                .accessibilityLabel(String(localized: "update.toast.mute", defaultValue: "Mute"))
                .accessibilityIdentifier("UpdateReadyToastMute")

                Button {
                    model.dismissUpdateReadyToast()
                } label: {
                    Image(systemName: "xmark")
                        .cmuxFont(size: 9, weight: .semibold)
                        .foregroundColor(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .safeHelp(String(localized: "update.toast.dismiss", defaultValue: "Dismiss"))
                .accessibilityLabel(String(localized: "update.toast.dismiss", defaultValue: "Dismiss"))
                .accessibilityIdentifier("UpdateReadyToastDismiss")
            }

            Text(String(localized: "update.toast.message", defaultValue: "The update is downloaded. Restart to finish installing."))
                .cmuxFont(size: 11)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                Button {
                    installing.retryTerminatingApplication()
                } label: {
                    Text(String(localized: "update.toast.restart", defaultValue: "Restart"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("UpdateReadyToastRestart")

                Button {
                    actions.requestRestartWhenIdle()
                } label: {
                    Text(String(localized: "update.toast.restartWhenIdle", defaultValue: "Restart When Idle"))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .accessibilityIdentifier("UpdateReadyToastRestartWhenIdle")
            }

            if let notes = installing.releaseNotes {
                Button {
                    openURL(notes.url)
                } label: {
                    HStack(spacing: 4) {
                        Text(String(localized: "update.toast.seeChanges", defaultValue: "See Changes"))
                            .cmuxFont(size: 10, weight: .medium)
                        Image(systemName: "arrow.up.right")
                            .cmuxFont(size: 8)
                    }
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("UpdateReadyToastSeeChanges")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("UpdateReadyToast")
    }

    private func title(for installing: UpdateState.Installing) -> String {
        if let version = installing.stagedVersion, !version.isEmpty {
            let format = String(localized: "update.toast.title.withVersion", defaultValue: "cmux %@ is ready")
            return String(format: format, version)
        }
        return String(localized: "update.toast.title", defaultValue: "Update ready")
    }
}
