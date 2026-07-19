#if os(iOS)
import CmuxMobileSupport
import SwiftUI
@preconcurrency import UIKit

/// The three-page, pre-auth introduction to cmux on iPhone.
struct OnboardingWelcomeFlowView: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.analytics) private var analytics
    @State private var pageIndex = 0
    @State private var isLogoBreathing = false

    var body: some View {
        ZStack {
            GameOfLifeHeader()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                TabView(selection: $pageIndex) {
                    brandPage.tag(0)
                    terminalPage.tag(1)
                    notificationPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageDots
                    .padding(.bottom, 12)
                primaryButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        }
        .accessibilityIdentifier("MobileOnboardingWelcome")
        .onAppear {
            analytics.capture("ios_onboarding_welcome_viewed", ["page": .int(pageIndex)])
            guard !accessibilityReduceMotion else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                isLogoBreathing = true
            }
        }
        .onChange(of: pageIndex) { _, newValue in
            analytics.capture("ios_onboarding_welcome_viewed", ["page": .int(newValue)])
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            if pageIndex < 2 {
                Button {
                    analytics.capture("ios_onboarding_welcome_skipped", ["page": .int(pageIndex)])
                    onFinished()
                } label: {
                    Text(L10n.string("mobile.onboarding.welcome.skip", defaultValue: "Skip"))
                        .font(.subheadline)
                }
                .accessibilityIdentifier("MobileOnboardingWelcomeSkipButton")
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var brandPage: some View {
        welcomePage(
            title: L10n.string(
                "mobile.onboarding.welcome.page1.title",
                defaultValue: "Your coding agents, in your pocket"
            ),
            body: L10n.string(
                "mobile.onboarding.welcome.page1.body",
                defaultValue: "cmux pairs with your Mac and brings your terminals and agents with you."
            )
        ) {
            VStack(spacing: 10) {
                ZStack {
                    Color.clear
                        .frame(width: 120, height: 120)
                        .mobileGlassCircle()
                    Image("CmuxLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                }
                Text("cmux")
                    .font(.system(size: 40, weight: .semibold))
            }
            .scaleEffect(accessibilityReduceMotion ? 1 : (isLogoBreathing ? 1.03 : 1))
        }
    }

    private var terminalPage: some View {
        welcomePage(
            title: L10n.string(
                "mobile.onboarding.welcome.page2.title",
                defaultValue: "Watch work happen live"
            ),
            body: L10n.string(
                "mobile.onboarding.welcome.page2.body",
                defaultValue: "Your Mac's cmux workspaces stream to your phone in real time — follow every agent from anywhere."
            )
        ) {
            OnboardingTerminalCardView(mode: .streaming)
        }
    }

    private var notificationPage: some View {
        welcomePage(
            title: L10n.string(
                "mobile.onboarding.welcome.page3.title",
                defaultValue: "Never miss a question"
            ),
            body: L10n.string(
                "mobile.onboarding.welcome.page3.body",
                defaultValue: "Get a push the moment an agent needs you — and answer right from your phone."
            )
        ) {
            ZStack {
                OnboardingTerminalCardView(mode: .idle)
                    .scaleEffect(0.92)
                    .blur(radius: 0.5)
                    .opacity(0.55)
                OnboardingNotificationMockView()
                    .padding(.horizontal, 10)
            }
        }
    }

    private func welcomePage<Visual: View>(
        title: String,
        body: String,
        @ViewBuilder visual: @escaping () -> Visual
    ) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 16) {
                visual()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: proxy.size.height * 0.52)

                Text(title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text(body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index == pageIndex ? Color.primary : Color.primary.opacity(0.25))
                    .frame(width: 7, height: 7)
            }
        }
        .animation(.snappy(duration: 0.2), value: pageIndex)
    }

    private var primaryButton: some View {
        Button(action: advance) {
            Text(pageIndex == 2
                ? L10n.string("mobile.onboarding.welcome.getStarted", defaultValue: "Get started")
                : L10n.string("mobile.onboarding.welcome.continue", defaultValue: "Continue"))
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .contentShape(.capsule)
        }
        .mobileGlassProminentButton()
        .accessibilityIdentifier("MobileOnboardingWelcomePrimaryButton")
    }

    private func advance() {
        guard pageIndex < 2 else {
            analytics.capture("ios_onboarding_welcome_completed", [:])
            onFinished()
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.2)) {
            pageIndex += 1
        }
    }
}
#endif
