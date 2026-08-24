#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The tour's Mac-linking stage: live discovery plus the connection choices.
///
/// The hero reflects ``WelcomeConnectionStatus`` (radar pulse while searching,
/// guidance when stalled, the Mac's name when linked). Below it, the two
/// connection methods are explained as selectable cards backed by
/// ``CmuxMobileShellModel/MobileConnectionMethod``; choosing Tailscale surfaces
/// the pairing-code scanner, matching the app-wide rule that manual pairing
/// authorizes Tailscale routes. Retry and completion controls live in the tour
/// footer, not here.
struct WelcomeConnectStageView: View {
    let status: WelcomeConnectionStatus
    let method: MobileConnectionMethod
    let accountEmail: String?
    let selectMethod: (MobileConnectionMethod) -> Void
    let scanPairingCode: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.analytics) private var analytics
    @Environment(\.openURL) private var openURL

    /// Whether the no-Mac guidance impression already fired this presentation,
    /// so repeated search stalls don't refire the funnel event.
    @State private var reportedInstallGuidance = false

    var body: some View {
        VStack(spacing: 24) {
            hero
            if case .linked = status {
                EmptyView()
            } else {
                macChecklist
            }
            if status == .stalled {
                installActions
            }
            methodSection
        }
        .accessibilityIdentifier("MobileWelcomeStage-connect")
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: status)
        .onAppear { reportInstallGuidanceIfNeeded() }
        .onChange(of: status) { _, _ in reportInstallGuidanceIfNeeded() }
    }

    // MARK: Hero

    @ViewBuilder
    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                if status == .searching, !reduceMotion {
                    WelcomeSearchPulse()
                }
                Circle()
                    .fill(heroIconBackground)
                    .frame(width: 84, height: 84)
                Image(systemName: heroSymbol)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(heroSymbolColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(height: 120)
            VStack(spacing: 6) {
                Text(heroTitle)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(heroSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileWelcomeConnectionHero")
    }

    private var heroSymbol: String {
        switch status {
        case .searching: "macbook.and.iphone"
        case .stalled: "questionmark"
        case .linked: "checkmark"
        }
    }

    private var heroIconBackground: Color {
        switch status {
        case .linked: .green.opacity(0.18)
        case .searching, .stalled: Color.accentColor.opacity(0.14)
        }
    }

    private var heroSymbolColor: Color {
        switch status {
        case .linked: .green
        case .searching, .stalled: .accentColor
        }
    }

    private var heroTitle: String {
        switch status {
        case .searching:
            L10n.string(
                "mobile.welcome.connect.searchingTitle",
                defaultValue: "Looking for your Mac…"
            )
        case .stalled:
            L10n.string(
                "mobile.welcome.connect.stalledTitle",
                defaultValue: "No Mac found yet"
            )
        case .linked(let macName):
            macName.map {
                String(
                    format: L10n.string(
                        "mobile.welcome.connect.linkedTitleFormat",
                        defaultValue: "Linked to %@"
                    ),
                    $0
                )
            } ?? L10n.string(
                "mobile.welcome.connect.linkedTitle",
                defaultValue: "Your Mac is linked"
            )
        }
    }

    private var heroSubtitle: String {
        switch status {
        case .searching:
            L10n.string(
                "mobile.welcome.connect.searchingSubtitle",
                defaultValue: "Any Mac signed in to your cmux account appears here automatically."
            )
        case .stalled:
            L10n.string(
                "mobile.welcome.connect.stalledSubtitle",
                defaultValue: "cmux has to be open on your Mac for your phone to find it. Check the steps below, then search again."
            )
        case .linked:
            L10n.string(
                "mobile.welcome.connect.linkedSubtitle",
                defaultValue: "Workspaces and agents from this Mac now stream to your phone."
            )
        }
    }

    // MARK: Mac checklist

    private var macChecklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("mobile.welcome.connect.checklistTitle", defaultValue: "On your Mac"))
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            checklistRow(
                index: 1,
                text: L10n.string(
                    "mobile.welcome.connect.checklistInstall",
                    defaultValue: "Get cmux at cmux.com"
                )
            )
            checklistRow(index: 2, text: checklistSignInText)
            checklistRow(
                index: 3,
                text: L10n.string(
                    "mobile.welcome.connect.checklistRunning",
                    defaultValue: "Keep cmux running"
                )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var checklistSignInText: String {
        if let accountEmail, !accountEmail.isEmpty {
            String(
                format: L10n.string(
                    "mobile.welcome.connect.checklistSignInFormat",
                    defaultValue: "Sign in as %@"
                ),
                accountEmail
            )
        } else {
            L10n.string(
                "mobile.welcome.connect.checklistSignIn",
                defaultValue: "Sign in with this same account"
            )
        }
    }

    private func checklistRow(index: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(index)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.14), in: Circle())
            Text(text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Install actions

    /// Recovery actions for the person whose Mac has no cmux yet: read about
    /// it on this phone, or hand the link straight to the Mac (AirDrop lists a
    /// nearby Mac first, which is exactly the machine being set up).
    private var installActions: some View {
        HStack(spacing: 10) {
            Button {
                analytics.capture("ios_welcome_install_link_opened", [:])
                openURL(CmuxMarketingLink.download)
            } label: {
                Label(
                    L10n.string("mobile.welcome.connect.getCmux", defaultValue: "Get cmux"),
                    systemImage: "arrow.down.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("MobileWelcomeGetCmux")
            ShareLink(item: CmuxMarketingLink.download) {
                Label(
                    L10n.string(
                        "mobile.welcome.connect.sendLink",
                        defaultValue: "Send Link to Mac"
                    ),
                    systemImage: "square.and.arrow.up"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("MobileWelcomeSendLink")
            .simultaneousGesture(TapGesture().onEnded {
                analytics.capture("ios_welcome_install_link_shared", [:])
            })
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Reports the no-Mac guidance impression once per presentation: the
    /// funnel edge for "reached connect and no Mac appeared".
    private func reportInstallGuidanceIfNeeded() {
        guard status == .stalled, !reportedInstallGuidance else { return }
        reportedInstallGuidance = true
        analytics.capture("ios_welcome_no_mac_guidance_shown", [:])
    }

    // MARK: Connection methods

    private var methodSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string(
                "mobile.welcome.connect.methodTitle",
                defaultValue: "How your phone reaches it"
            ))
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            WelcomeConnectionMethodCard(
                symbol: "bolt.shield",
                title: L10n.string(
                    "mobile.welcome.connect.methodAutomaticTitle",
                    defaultValue: "Auto-Connect"
                ),
                subtitle: L10n.string(
                    "mobile.welcome.connect.methodAutomaticSubtitle",
                    defaultValue: "End-to-end encrypted. Direct or over a local network when possible, through a cmux relay when not. Works anywhere, no setup."
                ),
                badge: L10n.string(
                    "mobile.welcome.connect.methodRecommended",
                    defaultValue: "Recommended"
                ),
                isSelected: method == .automatic,
                accessibilityID: "MobileWelcomeMethodAutomatic",
                select: { selectMethod(.automatic) }
            )
            WelcomeConnectionMethodCard(
                symbol: "network.badge.shield.half.filled",
                title: L10n.string(
                    "mobile.welcome.connect.methodTailscaleTitle",
                    defaultValue: "Tailscale Only"
                ),
                subtitle: L10n.string(
                    "mobile.welcome.connect.methodTailscaleSubtitle",
                    defaultValue: "Connect only over your own Tailscale network. Authorize each Mac once by scanning the pairing code it shows."
                ),
                badge: nil,
                isSelected: method == .tailscale,
                accessibilityID: "MobileWelcomeMethodTailscale",
                select: { selectMethod(.tailscale) }
            )
            if method == .tailscale {
                Button(action: scanPairingCode) {
                    Label(
                        L10n.string(
                            "mobile.welcome.connect.scanPairingCode",
                            defaultValue: "Scan Pairing Code"
                        ),
                        systemImage: "qrcode.viewfinder"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("MobileWelcomeScanPairingCode")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Text(L10n.string(
                "mobile.welcome.connect.localNetworkNote",
                defaultValue: "iOS may ask to allow local-network access. That is how cmux finds a Mac on the same Wi-Fi."
            ))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .animation(.snappy(duration: 0.2), value: method)
    }
}
#endif
