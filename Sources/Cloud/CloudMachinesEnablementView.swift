import AppKit
import CmuxFoundation
import SwiftUI

/// The Cloud tab's first-use outcome. Mirrors
/// ``CloudActivationCoordinator/State`` so the screen renders from plain
/// values (the app maps it in ``CloudMachinesEnablementPanel``; the
/// CloudWelcomeLab builds it directly).
enum CloudMachinesEnablementPhase: Equatable {
    enum Failure: Equatable {
        case requiresPro
        case signInRequired
        case serviceUnavailable
    }

    case disabled
    case enabling
    case enabled
    case failed(Failure)
    case cancelled
    case unavailable
}

/// First-use screen for the Cloud tab. It keeps the normal machines panel
/// untouched after ``CloudActivationCoordinator/State/enabled`` and gives
/// every setup outcome a recoverable action where one exists.
///
/// Before setup starts (Enable for Pro, Upgrade for Free) it introduces Cloud:
/// a title for the plan, four reasons, one action and the plan note. Every other outcome is a centered status: symbol,
/// title, one line, its action.
///
/// The screen paints the panel's opaque chrome color. The right sidebar's
/// backdrop is a behind-window material (or the translucent window fill when
/// backdrops are unified), which the dense machines tree mostly covers, but a
/// mostly empty onboarding card would otherwise let other windows show through.
///
/// It takes plain values and action closures only; the app wires its
/// coordinator and account flow in ``CloudMachinesEnablementPanel``.
struct CloudMachinesEnablementView: View {
    let phase: CloudMachinesEnablementPhase
    /// Whether a billing plan request has finished for this account. When it
    /// failed, the plan is still unknown and the server decides on enable.
    let billingPlanLoaded: Bool
    /// The account's plan is known (not just "a request finished").
    let isPlanKnown: Bool
    let isProActive: Bool
    /// Title for ``CloudMachinesEnablementPhase/unavailable`` (the feature
    /// flag or managed policy message).
    let unavailableMessage: String
    let chromeBackgroundColor: NSColor
    let onEnable: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onUpgrade: () -> Void
    /// Nil when there is no account flow to sign in with.
    let onSignIn: (() -> Void)?

    private static let contentMaxWidth: CGFloat = 360
    private static let statusMaxWidth: CGFloat = 280

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    content
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity)
                }
                .frame(minHeight: geometry.size.height, alignment: isIntroduction ? .top : .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: chromeBackgroundColor))
        .accessibilityIdentifier("CloudMachinesEnablement")
    }

    @ViewBuilder
    private var content: some View {
        if isIntroduction {
            introduction
                .frame(maxWidth: Self.contentMaxWidth)
                .padding(.vertical, 20)
        } else if isCheckingPlan {
            planChecking
        } else {
            status
                .frame(maxWidth: Self.statusMaxWidth)
                .padding(.vertical, 28)
        }
    }

    /// Before setup with a loaded (or failed) plan check: the welcome's pitch.
    private var isIntroduction: Bool {
        phase == .disabled && !isCheckingPlan
    }

    private var isCheckingPlan: Bool {
        (phase == .disabled || phase == .cancelled) && !billingPlanLoaded && !isPlanKnown
    }

    /// Free accounts see Upgrade to Pro in place of Enable Cloud.
    private var isProGated: Bool {
        isPlanKnown && !isProActive
    }

    // MARK: Introduction (Enable or Upgrade)

    private var introduction: some View {
        VStack(spacing: 0) {
            // A known Free plan is told what it needs; Pro and an unknown plan are invited.
            Text(isProGated
                ? String(localized: "cloud.enable.intro.requiresPro", defaultValue: "Upgrade to use cmux cloud")
                : String(localized: "cloud.enable.intro.title", defaultValue: "Use cmux cloud"))
                .cmuxFont(size: 20, weight: .bold)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(String(
                localized: "cloud.enable.subtitle",
                defaultValue: "Persistent cloud computers that open as regular cmux workspaces."
            ))
            .cmuxFont(size: 12)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
            CloudMachinesEnablementReasons()
                .padding(.top, 22)
            VStack(spacing: 8) {
                introductionAction
                Text(planNote)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 22)
        }
    }

    @ViewBuilder
    private var introductionAction: some View {
        if isProGated {
            introButton(
                String(localized: "cloud.enable.upgrade", defaultValue: "Upgrade to Pro"),
                identifier: "CloudMachinesEnableUpgradeButton",
                action: onUpgrade
            )
        } else {
            introButton(
                String(localized: "cloud.enable.action", defaultValue: "Enable Cloud"),
                identifier: "CloudMachinesEnableButton",
                action: onEnable
            )
        }
    }

    private func introButton(_ label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .frame(minWidth: 160)
        }
        .controlSize(.large)
        .cloudProminentButtonStyle()
        .accessibilityIdentifier(identifier)
    }

    /// A known Pro plan is told it is covered; Free and an unknown plan (the
    /// server decides on enable) are told which plans include Cloud.
    private var planNote: String {
        if isPlanKnown && isProActive {
            return String(localized: "cloud.welcome.note.included", defaultValue: "Included in your plan.")
        }
        return String(localized: "cloud.welcome.note.available", defaultValue: "Cloud is available on cmux Pro and Max.")
    }

    // MARK: Status (every other outcome)

    /// The plan check runs right after the account check; it reads the same.
    private var planChecking: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "cloud.enable.planChecking", defaultValue: "Checking your cmux plan…"))
                .cmuxFont(size: 13)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var status: some View {
        VStack(spacing: 0) {
            statusSymbol
                .frame(height: 36)
            Text(title)
                .cmuxFont(size: 17, weight: .bold)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 14)
            Text(subtitle)
                .cmuxFont(size: 13)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            statusActions
                .padding(.top, 18)
        }
    }

    @ViewBuilder
    private var statusSymbol: some View {
        if phase == .enabling {
            ProgressView()
                .controlSize(.regular)
                .accessibilityLabel(title)
        } else {
            Image(systemName: statusSymbolName)
                .font(.system(size: 30, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var statusSymbolName: String {
        switch phase {
        case .disabled, .cancelled, .enabling, .enabled, .failed(.requiresPro): return "cloud"
        case .failed(.signInRequired): return "person.crop.circle"
        case .failed(.serviceUnavailable): return "exclamationmark.icloud"
        case .unavailable: return "icloud.slash"
        }
    }

    @ViewBuilder
    private var statusActions: some View {
        switch phase {
        case .disabled, .cancelled:
            if isProGated {
                actionButton(
                    String(localized: "cloud.enable.upgrade", defaultValue: "Upgrade to Pro"),
                    prominent: true,
                    identifier: "CloudMachinesEnableUpgradeButton",
                    action: onUpgrade
                )
            } else {
                actionButton(
                    String(localized: "cloud.enable.action", defaultValue: "Enable Cloud"),
                    prominent: true,
                    identifier: "CloudMachinesEnableButton",
                    action: onEnable
                )
            }
        case .enabling:
            actionButton(
                String(localized: "cloud.enable.cancel", defaultValue: "Cancel"),
                prominent: false,
                identifier: "CloudMachinesEnableCancelButton",
                action: onCancel
            )
        case .failed(.requiresPro):
            actionPair {
                retryButton(prominent: false)
                actionButton(
                    String(localized: "cloud.enable.upgrade", defaultValue: "Upgrade to Pro"),
                    prominent: true,
                    identifier: "CloudMachinesEnableUpgradeButton",
                    action: onUpgrade
                )
            }
        case .failed(.signInRequired):
            if let onSignIn {
                actionPair {
                    retryButton(prominent: false)
                    actionButton(
                        String(localized: "cloud.enable.signIn.action", defaultValue: "Sign In"),
                        prominent: true,
                        identifier: "CloudMachinesEnableSignInButton",
                        action: onSignIn
                    )
                }
            } else {
                retryButton(prominent: true)
            }
        case .failed(.serviceUnavailable):
            retryButton(prominent: true)
        case .enabled, .unavailable:
            EmptyView()
        }
    }

    // MARK: Copy

    private var title: String {
        if isProGated {
            return String(localized: "cloud.enable.requiresPro.title", defaultValue: "Cloud Machines require cmux Pro")
        }
        switch phase {
        case .disabled, .cancelled, .enabled:
            return String(localized: "cloud.enable.title.enable", defaultValue: "Enable Cloud Machines")
        case .enabling:
            return String(localized: "cloud.enable.loading.title", defaultValue: "Setting up Cloud Machines…")
        case .failed(.requiresPro):
            return String(localized: "cloud.enable.requiresPro.title", defaultValue: "Cloud Machines require cmux Pro")
        case .failed(.signInRequired):
            return String(localized: "cloud.enable.signIn.title", defaultValue: "Sign in to use Cloud Machines")
        case .failed(.serviceUnavailable):
            return String(localized: "cloud.enable.failed.title", defaultValue: "Cloud setup is temporarily unavailable")
        case .unavailable:
            return unavailableMessage
        }
    }

    /// The status line. The introduction always uses the product line instead.
    private var subtitle: String {
        if isProGated {
            return String(localized: "cloud.enable.requiresPro.subtitle", defaultValue: "This account’s plan does not include Cloud machine access.")
        }
        switch phase {
        case .disabled, .enabled:
            return String(
                localized: "cloud.enable.subtitle",
                defaultValue: "Persistent cloud computers that open as regular cmux workspaces."
            )
        case .cancelled:
            return String(
                localized: "cloud.enable.cancelled.subtitle",
                defaultValue: "Cloud was not enabled. You can start setup again whenever you are ready."
            )
        case .enabling:
            return String(
                localized: "cloud.enable.loading.subtitle",
                defaultValue: "cmux is preparing the shared Cloud connection. This can take a moment."
            )
        case .failed(.requiresPro):
            return String(
                localized: "cloud.enable.requiresPro.subtitle",
                defaultValue: "This account’s plan does not include Cloud machine access."
            )
        case .failed(.signInRequired):
            return String(
                localized: "cloud.enable.signIn.subtitle",
                defaultValue: "Sign in to your cmux account, then retry Cloud setup."
            )
        case .failed(.serviceUnavailable):
            return String(
                localized: "cloud.enable.failed.subtitle",
                defaultValue: "The Cloud service could not be reached. Check your connection and retry."
            )
        case .unavailable:
            return String(
                localized: "cloud.enable.unavailable.subtitle",
                defaultValue: "Cloud Machines are unavailable on this Mac right now."
            )
        }
    }

    // MARK: Buttons

    private func retryButton(prominent: Bool) -> some View {
        actionButton(
            String(localized: "machines.unavailable.retry", defaultValue: "Retry"),
            prominent: prominent,
            identifier: "CloudMachinesEnableRetryButton",
            action: onRetry
        )
    }

    /// Two actions side by side, secondary first like a dialog; stacked when a
    /// translation does not fit the sidebar.
    private func actionPair<Content: View>(@ViewBuilder _ buttons: () -> Content) -> some View {
        let buttons = buttons()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
                .fixedSize()
            VStack(spacing: 8) { buttons }
        }
    }

    /// Large buttons, the primary one blue even in an inactive window.
    @ViewBuilder
    private func actionButton(
        _ label: String,
        prominent: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Text(label)
                .padding(.horizontal, 6)
        }
        // No shape here: the right sidebar gives every button its 6pt radius
        // (rightSidebarButtonBorderShape on the panel).
        .controlSize(.large)
        .accessibilityIdentifier(identifier)
        if prominent {
            button.cloudProminentButtonStyle()
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

extension View {
    /// `.borderedProminent` that stays blue when the window is inactive.
    /// The right sidebar forces its own color scheme
    /// (`RightSidebarPanelView`); when that disagrees with the window's
    /// appearance, AppKit draws the inactive gray bezel under SwiftUI's white
    /// prominent label and the button all but disappears after a click away.
    func cloudProminentButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .environment(\.controlActiveState, .key)
    }
}

/// Four reasons to enable Cloud: an accent symbol, a short title and one line.
/// Each restates a shipped capability from the Cloud overview docs.
private struct CloudMachinesEnablementReasons: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(
                symbol: "terminal",
                title: String(localized: "cloud.enable.reason.away", defaultValue: "Runs while you’re away"),
                detail: String(
                    localized: "cloud.enable.benefit.agents",
                    defaultValue: "Agents and terminals keep running after you close your laptop."
                )
            )
            row(
                symbol: "externaldrive",
                title: String(localized: "cloud.enable.reason.setUp", defaultValue: "Stays set up"),
                detail: String(
                    localized: "cloud.enable.benefit.files",
                    defaultValue: "Files and installed tools stay on the machine between sessions."
                )
            )
            row(
                symbol: "laptopcomputer",
                title: String(localized: "cloud.enable.reason.anyMac", defaultValue: "Opens on any Mac"),
                detail: String(
                    localized: "cloud.enable.benefit.reattach",
                    defaultValue: "Pick up where you left off from any Mac you sign in on."
                )
            )
            row(
                symbol: "person.2",
                title: String(localized: "cloud.enable.reason.team", defaultValue: "Shared with your team"),
                detail: String(
                    localized: "cloud.enable.reason.team.detail",
                    defaultValue: "Invite teammates, and share any port with a private link."
                )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func row(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .cmuxFont(size: 16)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .cmuxFont(size: 13, weight: .semibold)
                Text(detail)
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
