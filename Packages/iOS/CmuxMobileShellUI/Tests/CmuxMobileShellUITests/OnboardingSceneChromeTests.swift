#if os(iOS)
@testable import CmuxMobileShellUI
import Foundation
import Testing
import UIKit

@Suite struct OnboardingSceneChromeTests {
    @Test func productPagesKeepExpectedNavigationChrome() {
        let agents = OnboardingSceneChrome(
            stage: .agents,
            isAuthenticated: true,
            connectionPhase: .searching
        )
        let notifications = OnboardingSceneChrome(
            stage: .notifications,
            isAuthenticated: true,
            connectionPhase: .searching
        )

        #expect(!agents.showsBack)
        #expect(agents.showsSkip)
        #expect(agents.primaryTitle != nil)
        #expect(agents.secondaryTitle == nil)

        #expect(notifications.showsBack)
        #expect(notifications.showsSkip)
        #expect(notifications.primaryTitle != nil)
        #expect(notifications.secondaryTitle == nil)
    }

    @Test func connectionChromeFollowsAuthenticationAndDiscoveryPhase() {
        let signIn = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: false,
            connectionPhase: .searching
        )
        let searching = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .searching
        )
        let idle = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .idle
        )
        let fallback = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .fallback
        )
        let ready = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .ready
        )

        #expect(signIn.showsBack)
        #expect(!signIn.showsSkip)
        #expect(signIn.primaryTitle == nil)
        #expect(signIn.secondaryTitle == nil)

        #expect(searching.primaryTitle == nil)
        #expect(searching.secondaryTitle == nil)
        #expect(idle.primaryTitle != nil)
        #expect(idle.secondaryTitle == nil)
        #expect(fallback.primaryTitle != nil)
        #expect(fallback.secondaryTitle != nil)
        #expect(ready.primaryTitle != nil)
        #expect(ready.secondaryTitle == nil)
    }

    @Test func screenshotLanguageMatchesTheSupportedLocale() {
        #expect(
            OnboardingScreenshotLanguage.resolve(
                locale: Locale(identifier: "en_US")
            ) == .english
        )
        #expect(
            OnboardingScreenshotLanguage.resolve(
                locale: Locale(identifier: "ja_JP")
            ) == .japanese
        )
        #expect(
            OnboardingScreenshotLanguage.resolve(
                locale: Locale(identifier: "fr_FR")
            ) == .english
        )
    }

    @Test @MainActor func everyLocalizedOnboardingScreenshotLoads() async {
        for content in OnboardingScreenshot.Content.allCases {
            for language in OnboardingScreenshotLanguage.allCases {
                let image = await OnboardingScreenshot.image(
                    content: content,
                    language: language
                )
                #expect(image.size.width > 0)
                #expect(image.size.height > 0)
            }
        }
    }

    @Test @MainActor func onboardingCopyUsesNativeLineBalancing() {
        let label = OnboardingBalancedText.makeLabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.text = "See every workspace and its latest activity, wherever you are."
        let maximumWidth: CGFloat = 360
        let maximumHeight = label.sizeThatFits(
            CGSize(width: maximumWidth, height: .greatestFiniteMagnitude)
        ).height
        let balancedSize = OnboardingBalancedText.balancedSize(
            for: label,
            maximumWidth: maximumWidth
        )

        #expect(label.numberOfLines == 0)
        #expect(label.lineBreakMode == .byWordWrapping)
        #expect(label.lineBreakStrategy == .pushOut)
        #expect(balancedSize.width < maximumWidth)
        #expect(balancedSize.height == ceil(maximumHeight))
    }
}
#endif
