#if os(iOS)
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI

/// First-run onboarding that explains what cmux is and how the phone connects to
/// a Mac, then hands off to the existing pairing flow.
///
/// This view is deliberately pairing-ignorant. It owns no auth, store, or
/// pairing state: it walks the user through the explanatory pages, ends on an
/// "enable notifications" opt-in (driven through the injected
/// ``MobilePushCoordinator``, and skipped when notifications are already on),
/// then calls ``onComplete``. The caller decides what "complete" means:
///
/// - First launch: presented post-authentication, in front of the never-paired
///   add-device state. The root view marks onboarding seen and falls through to
///   `DisconnectedWorkspaceShellView`, which already auto-presents `PairingView`,
///   so the "pair now" handoff is automatic and nothing here is duplicated.
/// - Settings ("How pairing works"): the entry just dismisses.
///
/// The `onComplete` closure is the extensibility seam. A future "add your own
/// Linux/Mac servers" (Hive) path can branch the final CTA without changing this
/// view's body.
struct OnboardingFlowView: View {
    /// Called when the user finishes the last page or skips. The caller marks the
    /// flow seen (first launch) and/or dismisses the presentation.
    let onComplete: () -> Void

    /// Which setup gate the "Trouble connecting?" help should highlight, or `nil`
    /// for a plain reference with no "You are here" marker. First-run onboarding
    /// defaults to the never-paired gate (the user has not paired yet); Settings
    /// re-entry passes `nil`, since reaching Settings means every gate is cleared.
    var setupHelpHighlight: MobileSetupGuidanceState? = .signedInNeverPaired

    @State private var pageIndex = 0
    @State private var isShowingSetupHelp = false
    @State private var isEnablingNotifications = false
    @Environment(\.analytics) private var analytics
    @Environment(MobilePushCoordinator.self) private var pushCoordinator

    /// The pages to show. The final "enable notifications" page is dropped when
    /// notifications are already on, so a returning/Settings user never sees a
    /// redundant opt-in. `isEnabled` only changes when the user acts on that very
    /// page (which immediately completes the flow), so the list is stable while
    /// onboarding is on screen.
    private var pages: [OnboardingPage] {
        OnboardingPage.allPages.filter { page in
            page.kind != .enableNotifications || !pushCoordinator.isEnabled
        }
    }

    private var currentPage: OnboardingPage? {
        guard pages.indices.contains(pageIndex) else { return nil }
        return pages[pageIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            TabView(selection: $pageIndex) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            footer
        }
        .background(PlatformPalette.systemBackground.ignoresSafeArea())
        .interactiveDismissDisabled()
        .accessibilityIdentifier("MobileOnboardingFlow")
        .sheet(isPresented: $isShowingSetupHelp) {
            SetupHelpView(highlight: setupHelpHighlight) { isShowingSetupHelp = false }
        }
        .onAppear {
            analytics.capture("ios_onboarding_viewed", ["page": .int(0)])
        }
        .onChange(of: pageIndex) { _, newValue in
            analytics.capture("ios_onboarding_viewed", ["page": .int(newValue)])
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Button {
                analytics.capture("ios_onboarding_skipped", ["page": .int(pageIndex)])
                onComplete()
            } label: {
                Text(L10n.string("mobile.onboarding.skip", defaultValue: "Skip"))
                    .font(.subheadline)
            }
            .accessibilityIdentifier("MobileOnboardingSkipButton")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var footer: some View {
        if currentPage?.kind == .enableNotifications {
            notificationsFooter
        } else {
            infoFooter
        }
    }

    private var infoFooter: some View {
        VStack(spacing: 12) {
            Button {
                advance()
            } label: {
                Text(isLastPage
                    ? L10n.string("mobile.onboarding.getStarted", defaultValue: "Get started")
                    : L10n.string("mobile.onboarding.next", defaultValue: "Next"))
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .contentShape(.capsule)
            }
            .mobileGlassProminentButton()
            .accessibilityIdentifier("MobileOnboardingPrimaryButton")

            Button {
                analytics.capture("ios_onboarding_help_opened", ["page": .int(pageIndex)])
                isShowingSetupHelp = true
            } label: {
                Text(L10n.string("mobile.onboarding.troubleConnecting", defaultValue: "Trouble connecting?"))
                    .font(.subheadline)
            }
            .accessibilityIdentifier("MobileOnboardingHelpButton")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    /// Footer for the final "enable notifications" page: the primary button fires
    /// the OS permission prompt (or routes to Settings if previously denied),
    /// then completes; "Not now" completes without enabling. Either way the flow
    /// finishes and hands off to pairing.
    private var notificationsFooter: some View {
        VStack(spacing: 12) {
            Button {
                guard !isEnablingNotifications else { return }
                isEnablingNotifications = true
                Task { @MainActor in
                    await pushCoordinator.enableOrOpenSettings(trigger: "onboarding")
                    isEnablingNotifications = false
                    analytics.capture("ios_onboarding_completed", [:])
                    onComplete()
                }
            } label: {
                Text(L10n.string("mobile.onboarding.enableNotifications", defaultValue: "Enable notifications"))
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .contentShape(.capsule)
            }
            .mobileGlassProminentButton()
            .disabled(isEnablingNotifications)
            .accessibilityIdentifier("MobileOnboardingEnableNotificationsButton")

            Button {
                analytics.capture("ios_onboarding_notifications_skipped", ["page": .int(pageIndex)])
                onComplete()
            } label: {
                Text(L10n.string("mobile.onboarding.notificationsNotNow", defaultValue: "Not now"))
                    .font(.subheadline)
            }
            .disabled(isEnablingNotifications)
            .accessibilityIdentifier("MobileOnboardingNotificationsNotNowButton")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private var isLastPage: Bool {
        pageIndex >= pages.count - 1
    }

    private func advance() {
        if isLastPage {
            analytics.capture("ios_onboarding_completed", [:])
            onComplete()
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            pageIndex += 1
        }
    }
}
#endif
