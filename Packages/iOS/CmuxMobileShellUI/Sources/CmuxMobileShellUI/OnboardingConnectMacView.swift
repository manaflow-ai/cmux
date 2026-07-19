#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// The focused first-pairing screen shown after authentication.
struct OnboardingConnectMacView: View {
    let showAddDevice: () -> Void
    let signOut: () -> Void
    var store: CMUXMobileShellStore?

    @Environment(\.analytics) private var analytics
    @State private var isShowingSettings = false
    @State private var isShowingHelp = false

    private static let cmuxURL = URL(string: "https://cmux.com")!

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer(minLength: 12)
                iconLockup
                heading
                steps
                actions
                Spacer(minLength: 12)
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        MobileWorkspaceSettingsIcon()
                    }
                    .accessibilityLabel(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
                }
            }
            .mobileInlineNavigationTitle()
        }
        .accessibilityIdentifier("MobileOnboardingConnect")
        .sheet(isPresented: $isShowingSettings) {
            MobileSettingsView(
                connectedHostName: "",
                rescanQR: nil,
                signOut: signOut,
                store: store
            )
        }
        .sheet(isPresented: $isShowingHelp) {
            SetupHelpView(highlight: .signedInNeverPaired) { isShowingHelp = false }
        }
        .task {
            await store?.loadPairedMacs()
        }
        .onAppear {
            analytics.capture("ios_onboarding_connect_viewed", [:])
        }
    }

    private var iconLockup: some View {
        ZStack {
            Color.clear
                .frame(width: 112, height: 112)
                .mobileGlassCircle()
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
        }
    }

    private var heading: some View {
        VStack(spacing: 10) {
            Text(L10n.string("mobile.onboarding.connect.title", defaultValue: "Connect your Mac"))
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(L10n.string(
                "mobile.onboarding.connect.subtitle",
                defaultValue: "cmux on your Mac runs the agents. This iPhone is your remote."
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
        }
    }

    private var steps: some View {
        VStack(spacing: 12) {
            Link(destination: Self.cmuxURL) {
                stepCard(
                    index: "1",
                    title: L10n.string(
                        "mobile.onboarding.connect.step1.title",
                        defaultValue: "Get cmux on your Mac"
                    ),
                    body: L10n.string(
                        "mobile.onboarding.connect.step1.body",
                        defaultValue: "Free download at cmux.com"
                    ),
                    showsLinkAccessory: true
                )
            }
            .buttonStyle(.plain)

            stepCard(
                index: "2",
                title: L10n.string(
                    "mobile.onboarding.connect.step2.title",
                    defaultValue: "Pair this iPhone"
                ),
                body: L10n.string(
                    "mobile.onboarding.connect.step2.body",
                    defaultValue: "In cmux on your Mac, choose Pair iPhone, then scan the code."
                ),
                showsLinkAccessory: false
            )
        }
        .frame(maxWidth: 360)
    }

    private func stepCard(
        index: String,
        title: String,
        body: String,
        showsLinkAccessory: Bool
    ) -> some View {
        HStack(spacing: 14) {
            Text(index)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if showsLinkAccessory {
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .mobileGlassField(cornerRadius: 20)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                analytics.capture("ios_onboarding_connect_pair_opened", [:])
                showAddDevice()
            } label: {
                Text(L10n.string(
                    "mobile.onboarding.connect.pairButton",
                    defaultValue: "Scan pairing code"
                ))
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .contentShape(.capsule)
            }
            .mobileGlassProminentButton()
            .accessibilityIdentifier("MobileOnboardingConnectPairButton")

            Button {
                analytics.capture("ios_onboarding_connect_help_opened", [:])
                isShowingHelp = true
            } label: {
                Text(L10n.string(
                    "mobile.onboarding.connect.help",
                    defaultValue: "How pairing works"
                ))
                .font(.subheadline)
            }
            .accessibilityIdentifier("MobileOnboardingConnectHelpButton")
        }
        .frame(maxWidth: 360)
    }
}
#endif
