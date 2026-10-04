import AppKit
import CmuxFoundation
import SwiftUI

/// What the welcome window's one prominent button does for this account.
enum CloudWelcomeNextStep: Equatable {
    case signIn
    case upgrade
    case enable
    /// The plan is not known yet (or could not be loaded): open the Cloud tab,
    /// whose own gate decides between Upgrade and Enable.
    case openCloud

    static func resolve(isAuthenticated: Bool, isPlanKnown: Bool, isPro: Bool) -> CloudWelcomeNextStep {
        guard isAuthenticated else { return .signIn }
        guard isPlanKnown else { return .openCloud }
        return isPro ? .enable : .upgrade
    }
}

/// The welcome layouts still being compared (Help > Show Cloud Welcome, and
/// the CloudWelcomeLab). The winner stays; the rest go before shipping.
enum CloudWelcomeLayout: Equatable {
    /// Title and "New" badge at the top of the panel, above the subtitle.
    case titleInPanel
    /// "Introducing" over a larger "cmux Cloud" and the "New" badge, above the hero.
    case stacked
    /// stacked without the "New" badge.
    case stackedNoBadge
    /// stacked over a larger, centered machine list (no prompt): the open
    /// workspace on two terminals.
    case machineFocus
    /// machineFocus without the "New" badge.
    case machineFocusNoBadge

    static let allCases: [CloudWelcomeLayout] = [
        .titleInPanel, .stacked, .stackedNoBadge, .machineFocus, .machineFocusNoBadge,
    ]

    var titleIsOnTop: Bool { self != .titleInPanel }
    var showsBadge: Bool { self != .stackedNoBadge && self != .machineFocusNoBadge }
    var isMachineFocus: Bool { self == .machineFocus || self == .machineFocusNoBadge }
}

/// "Introducing cmux Cloud": shown once on launch (new users, and existing
/// users after the update that ships it). Glass frame, a hero built from the
/// Cloud tree's own rows, and a solid panel with the reasons and the next step.
///
/// Takes plain values (no app objects) so the same view renders in the app and
/// in a standalone lab; ``CloudWelcomeWindowController`` feeds it the account.
struct CloudWelcomeView: View {
    let nextStep: CloudWelcomeNextStep
    var layout: CloudWelcomeLayout = .titleInPanel
    let onNotNow: () -> Void
    let onNext: (CloudWelcomeNextStep) -> Void

    static let windowWidth: CGFloat = 580
    private static let cornerRadius: CGFloat = 22
    private static let panelCornerRadius: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            if layout.titleIsOnTop {
                titleRow
                    .frame(maxWidth: .infinity)
                    .padding(.top, 26)
                    .padding(.bottom, 2)
            }
            CloudWelcomeHero(compact: layout.titleIsOnTop, machineFocus: layout.isMachineFocus)
            panel
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(width: Self.windowWidth)
        .background(windowBackground)
        .accessibilityIdentifier("CloudWelcomeWindow")
        .modifier(CloudWelcomeInjectionRedraw())
    }

    @ViewBuilder
    private var windowBackground: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .ignoresSafeArea()
        } else {
            CloudWelcomeVisualEffect()
                .ignoresSafeArea()
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if layout == .titleInPanel {
                titleRow
                subtitle
                    .cmuxFont(size: 13)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                // The title is above the hero, so the subtitle leads the panel.
                subtitle
                    .cmuxFont(size: 15, weight: .medium)
            }
            VStack(alignment: .leading, spacing: 12) {
                CloudWelcomeReasonRow(
                    symbol: "terminal",
                    text: String(
                        localized: "cloud.enable.benefit.agents",
                        defaultValue: "Agents and terminals keep running after you close your laptop."
                    )
                )
                CloudWelcomeReasonRow(
                    symbol: "externaldrive",
                    text: String(
                        localized: "cloud.enable.benefit.files",
                        defaultValue: "Files and installed tools stay on the machine between sessions."
                    )
                )
                CloudWelcomeReasonRow(
                    symbol: "laptopcomputer",
                    text: String(
                        localized: "cloud.enable.benefit.reattach",
                        defaultValue: "Pick up where you left off from any Mac you sign in on."
                    )
                )
            }
            .padding(.top, 16)
            footer
                .padding(.top, 20)
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 16, trailing: 24))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var titleRow: some View {
        if layout.titleIsOnTop {
            VStack(spacing: 2) {
                Text(String(localized: "cloud.welcome.title.eyebrow", defaultValue: "Introducing"))
                    .cmuxFont(size: 13, weight: .medium)
                    .foregroundStyle(.secondary)
                HStack(alignment: .center, spacing: 10) {
                    // The product name, not a sentence: the same in every language.
                    Text(verbatim: "cmux Cloud")
                        .cmuxFont(size: 30, weight: .bold)
                    if layout.showsBadge {
                        newBadge
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        } else {
            inlineTitleRow
        }
    }

    private var inlineTitleRow: some View {
        HStack(alignment: .center, spacing: 9) {
            Text(String(localized: "cloud.welcome.title", defaultValue: "Introducing cmux Cloud"))
                .cmuxFont(size: 24, weight: .bold)
                .accessibilityAddTraits(.isHeader)
            newBadge
        }
    }

    private var newBadge: some View {
        Text(String(localized: "cloud.welcome.newBadge", defaultValue: "New"))
            .cmuxFont(size: 12, weight: .medium)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule(style: .continuous).fill(Color.accentColor.opacity(0.18)))
    }

    private var subtitle: Text {
        Text(String(
            localized: "cloud.enable.subtitle",
            defaultValue: "Persistent cloud computers that open as regular cmux workspaces."
        ))
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(noteLines, id: \.self) { line in
                    Text(line)
                }
            }
            .cmuxFont(size: 11)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(action: onNotNow) {
                Text(String(localized: "common.notNow", defaultValue: "Not Now"))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("CloudWelcomeNotNowButton")
            Button {
                onNext(nextStep)
            } label: {
                Text(primaryLabel)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .environment(\.controlActiveState, .key)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("CloudWelcomePrimaryButton")
        }
    }

    private var primaryLabel: String {
        switch nextStep {
        case .signIn:
            return String(localized: "cloud.enable.signIn.action", defaultValue: "Sign In")
        case .upgrade:
            return String(localized: "cloud.enable.upgrade", defaultValue: "Upgrade to Pro")
        case .enable:
            return String(localized: "cloud.enable.action", defaultValue: "Enable Cloud")
        case .openCloud:
            return String(localized: "cloud.welcome.setUp", defaultValue: "Set Up Cloud")
        }
    }

    private var noteLines: [String] {
        let available = String(
            localized: "cloud.welcome.note.available",
            defaultValue: "Cloud is available on cmux Pro and Max."
        )
        switch nextStep {
        case .enable:
            return [String(localized: "cloud.welcome.note.included", defaultValue: "Included in your plan.")]
        case .signIn, .upgrade, .openCloud:
            return [available]
        }
    }
}

/// Behind-window material for macOS before 26 (no Liquid Glass there).
private struct CloudWelcomeVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct CloudWelcomeReasonRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .cmuxFont(size: 14)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .cmuxFont(size: 13)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#if CMUX_INJECTION
/// Local hot reload while iterating on this window (InjectionIII). Compiled only
/// when a local build sets CMUX_INJECTION (~/cmux-injection.xcconfig); never in CI.
@MainActor
private final class CloudWelcomeInjection: ObservableObject {
    static let shared = CloudWelcomeInjection()
    @Published private(set) var generation = 0

    private init() {
        Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle")?.load()
        NotificationCenter.default.addObserver(
            forName: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.generation += 1 }
        }
    }
}

/// Rebuilds the window's view tree after each injection so new code shows.
private struct CloudWelcomeInjectionRedraw: ViewModifier {
    @ObservedObject private var injection = CloudWelcomeInjection.shared

    func body(content: Content) -> some View {
        content.id(injection.generation)
    }
}
#else
private struct CloudWelcomeInjectionRedraw: ViewModifier {
    func body(content: Content) -> some View { content }
}
#endif
