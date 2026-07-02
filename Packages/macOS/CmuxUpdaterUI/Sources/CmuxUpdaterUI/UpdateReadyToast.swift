import CmuxFoundation
public import SwiftUI
public import CmuxUpdater
import AppKit

/// Positions ``UpdateReadyToast`` in the window's bottom-trailing corner above the terminal
/// content. The window root mounts this as its top layer; it renders nothing (and hit-tests
/// nothing) while no toast is due or no actions host exists.
public struct UpdateReadyToastOverlay: View {
    private let model: UpdateStateModel
    private let actions: (any UpdateActionsHost)?

    /// Creates the overlay. `actions` is optional so call sites can pass a not-yet-wired host.
    public init(model: UpdateStateModel, actions: (any UpdateActionsHost)?) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        if let actions {
            UpdateReadyToast(model: model, actions: actions)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding([.bottom, .trailing], 16)
        }
    }
}

/// A transient corner toast shown when an update has been downloaded and staged in the
/// background: one click on "Restart" finishes the install.
///
/// Rendered by the window root as a bottom-corner overlay; visibility is derived entirely
/// from ``UpdateStateModel/updateReadyToastInstalling`` (staged auto-update present, not
/// dismissed for this version, restart-when-idle not armed).
public struct UpdateReadyToast: View {
    private let model: UpdateStateModel
    private let actions: any UpdateActionsHost
    @Environment(\.openURL) private var openURL

    /// Creates the toast bound to the observable update state.
    public init(model: UpdateStateModel, actions: any UpdateActionsHost) {
        self.model = model
        self.actions = actions
    }

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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .cmuxFont(size: 12)
                    .foregroundStyle(.tint)

                Text(title(for: installing))
                    .cmuxFont(size: 12, weight: .semibold)
                    .lineLimit(1)

                Spacer(minLength: 12)

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

            HStack(spacing: 8) {
                if let notes = installing.releaseNotes {
                    Button(String(localized: "update.toast.seeChanges", defaultValue: "See Changes")) {
                        openURL(notes.url)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("UpdateReadyToastSeeChanges")
                }

                Spacer(minLength: 8)

                Button(String(localized: "update.toast.restartWhenIdle", defaultValue: "Restart When Idle")) {
                    actions.requestRestartWhenIdle()
                }
                .controlSize(.small)
                .accessibilityIdentifier("UpdateReadyToastRestartWhenIdle")

                Button(String(localized: "update.toast.restart", defaultValue: "Restart")) {
                    installing.retryTerminatingApplication()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("UpdateReadyToastRestart")
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("UpdateReadyToast")
    }

    private func title(for installing: UpdateState.Installing) -> String {
        if let version = installing.stagedVersion, !version.isEmpty {
            return String(localized: "update.toast.title.withVersion", defaultValue: "cmux \(version) is ready")
        }
        return String(localized: "update.toast.title", defaultValue: "Update ready")
    }
}
