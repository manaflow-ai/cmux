#if os(iOS)
@testable import CmuxMobileShellUI
import Foundation
import SwiftUI
import Testing
import UIKit

@Suite struct OnboardingSceneChromeTests {
    @Test func welcomeKeepsExpectedNavigationChrome() {
        let welcome = OnboardingSceneChrome(
            stage: .welcome,
            connectionPhase: .searching
        )

        #expect(!welcome.showsBack)
        #expect(welcome.showsSkip)
        #expect(welcome.primaryTitle != nil)
        #expect(welcome.secondaryTitle == nil)
    }

    @Test func connectionChromeFollowsDiscoveryPhase() {
        let searching = OnboardingSceneChrome(
            stage: .connect,
            connectionPhase: .searching
        )
        let idle = OnboardingSceneChrome(
            stage: .connect,
            connectionPhase: .idle
        )
        let automaticFallback = OnboardingSceneChrome(
            stage: .connect,
            connectionPhase: .fallback
        )
        let tailscaleFallback = OnboardingSceneChrome(
            stage: .connect,
            connectionPhase: .fallback,
            connectionMethod: .tailscale
        )
        let ready = OnboardingSceneChrome(
            stage: .connect,
            connectionPhase: .ready
        )

        #expect(searching.showsBack)
        #expect(searching.showsSkip)
        #expect(searching.primaryTitle == nil)
        #expect(searching.secondaryTitle == nil)
        #expect(idle.primaryTitle != nil)
        #expect(idle.secondaryTitle == nil)
        // QR fallback stays reachable for either method: whichever action is
        // not primary becomes the secondary.
        #expect(automaticFallback.primaryTitle != nil)
        #expect(automaticFallback.secondaryTitle != nil)
        #expect(tailscaleFallback.primaryTitle != nil)
        #expect(tailscaleFallback.secondaryTitle != nil)
        #expect(tailscaleFallback.primaryTitle != automaticFallback.primaryTitle)
        #expect(ready.primaryTitle != nil)
        #expect(ready.secondaryTitle == nil)
        #expect(!ready.showsSkip)
    }

    @Test func pushChromeOffersEnableAndNotNow() {
        let push = OnboardingSceneChrome(
            stage: .push,
            connectionPhase: .searching
        )

        #expect(push.showsBack)
        // "Not Now" is the one decline affordance; no duplicate header Skip.
        #expect(!push.showsSkip)
        #expect(push.primaryTitle != nil)
        #expect(push.secondaryTitle != nil)
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
                for appearance in OnboardingScreenshotAppearance.allCases {
                    let image = await OnboardingScreenshot.image(
                        content: content,
                        language: language,
                        appearance: appearance
                    )
                    #expect(image.size.width > 0)
                    #expect(image.size.height > 0)
                }
            }
        }
    }

    @Test @MainActor func deviceFrameUsesFullResolutionProductArtwork() async throws {
        for appearance in OnboardingScreenshotAppearance.allCases {
            let frame = await OnboardingScreenshot.deviceFrameImage(appearance: appearance)
            let framePixels = try #require(frame.cgImage)
            #expect(framePixels.width == 1_470)
            #expect(framePixels.height == 3_000)
        }
        let mask = await OnboardingScreenshot.screenMaskImage()
        let maskPixels = try #require(mask.cgImage)

        #expect(maskPixels.width == 1_320)
        #expect(maskPixels.height == 2_868)
    }

    @Test func screenshotAppearanceMatchesTheSystemColorScheme() {
        #expect(OnboardingScreenshotAppearance.resolve(colorScheme: .light) == .light)
        #expect(OnboardingScreenshotAppearance.resolve(colorScheme: .dark) == .dark)
    }

    @Test @MainActor func onboardingCopyUsesNativeLineBalancing() {
        let label = OnboardingBalancedText.makeLabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.text = "Review every agent alert in one feed, even when push alerts are off."
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

    @Test @MainActor func onboardingSubtitlesCanBeCappedAtTwoLines() {
        let label = OnboardingBalancedText.makeLabel()
        OnboardingBalancedText.configure(
            label,
            text: "Use the same cmux account on both devices. Your Mac connects automatically.",
            role: .body,
            alignment: .center,
            maximumNumberOfLines: 2
        )
        let balancedSize = OnboardingBalancedText.balancedSize(
            for: label,
            maximumWidth: 360
        )

        #expect(label.numberOfLines == 2)
        #expect(balancedSize.width > 120)
    }
}
#endif
