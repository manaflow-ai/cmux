#if os(iOS)
import Foundation
import SwiftUI
import UIKit

/// Full-height Simulator captures from the production workspace list and
/// notification feed preview entrypoints. The preview is content-first, with
/// one quiet card around the capture instead of a decorative hardware mockup.
struct OnboardingScreenshot: View {
    enum Content: String, CaseIterable {
        case workspaces
        case notifications

        var accessibilityIdentifier: String {
            "MobileOnboardingScreenshot-\(rawValue)"
        }
    }

    let content: Content
    let accessibilityLabel: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.locale) private var locale
    @State private var screenshot: UIImage?

    var body: some View {
        OnboardingScreenshotCard {
            ZStack {
                Color(.systemBackground)
                if let screenshot {
                    Image(uiImage: screenshot)
                        .resizable()
                        .scaledToFill()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: preferredFrameHeight, alignment: .top)
        .opacity(screenshot == nil ? 0 : 1)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(
            screenshot != nil
                ? content.accessibilityIdentifier
                : "MobileOnboardingScreenshot-loading"
        )
        .task(id: resourceName) {
            screenshot = nil
            let loadedScreenshot = await Self.image(
                content: content,
                language: language,
                appearance: appearance
            )
            guard !Task.isCancelled else { return }
            screenshot = loadedScreenshot
        }
    }

    private var preferredFrameHeight: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 360
        }
        return horizontalSizeClass == .regular ? 520 : 440
    }

    private var language: OnboardingScreenshotLanguage {
        OnboardingScreenshotLanguage.resolve(locale: locale)
    }

    private var appearance: OnboardingScreenshotAppearance {
        OnboardingScreenshotAppearance.resolve(colorScheme: colorScheme)
    }

    private var resourceName: String {
        Self.resourceName(
            content: content,
            language: language,
            appearance: appearance
        )
    }

    @MainActor
    static func image(
        content: Content,
        language: OnboardingScreenshotLanguage,
        appearance: OnboardingScreenshotAppearance
    ) async -> UIImage {
        let resourceName = resourceName(
            content: content,
            language: language,
            appearance: appearance
        )
        return await cachedImage(resourceName: resourceName)
    }

    /// Legacy artwork accessors kept for the App Store asset validation tests.
    /// The onboarding surface intentionally renders the product capture in a
    /// simple card and does not load these frame layers.
    @MainActor
    static func deviceFrameImage(
        appearance: OnboardingScreenshotAppearance
    ) async -> UIImage {
        await cachedImage(resourceName: deviceFrameResourceName(appearance: appearance))
    }

    @MainActor
    static func screenMaskImage() async -> UIImage {
        await cachedImage(resourceName: screenMaskResourceName)
    }

    @MainActor
    private static func cachedImage(resourceName: String) async -> UIImage {
        let cacheKey = resourceName as NSString
        if let cachedImage = screenshotCache.object(forKey: cacheKey) {
            return cachedImage
        }

        guard let loaded = await loadImage(resourceName: resourceName) else {
            assertionFailure("Missing onboarding image: \(resourceName).png")
            return UIImage()
        }
        screenshotCache.setObject(
            loaded.image,
            forKey: cacheKey,
            cost: loaded.cost
        )
        return loaded.image
    }

    @concurrent
    private static func loadImage(
        resourceName: String
    ) async -> (image: UIImage, cost: Int)? {
        guard let url = Bundle.module.url(
            forResource: resourceName,
            withExtension: "png"
        ), let data = try? Data(contentsOf: url),
              let sourceImage = UIImage(data: data, scale: 3),
              let preparedImage = await sourceImage.byPreparingForDisplay() else {
            return nil
        }
        return (preparedImage, data.count)
    }

    @MainActor private static let screenshotCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 3 + Content.allCases.count
            * OnboardingScreenshotLanguage.allCases.count
            * OnboardingScreenshotAppearance.allCases.count
        return cache
    }()

    /// Bezel artwork per appearance: the silver product frame reads as a
    /// hardware photo on light pages, while dark pages get the Deep Blue
    /// colorway so the bezel does not glow against the dark backdrop. Both
    /// PNGs share frameit's exact screen geometry, so one mask serves both.
    private static func deviceFrameResourceName(
        appearance: OnboardingScreenshotAppearance
    ) -> String {
        switch appearance {
        case .light:
            return "Onboarding-iPhone-17-Pro-Max-Silver"
        case .dark:
            return "Onboarding-iPhone-17-Pro-Max-Deep-Blue"
        }
    }

    private static let screenMaskResourceName =
        "Onboarding-iPhone-17-Pro-Max-Screen-Mask"

    private static func resourceName(
        content: Content,
        language: OnboardingScreenshotLanguage,
        appearance: OnboardingScreenshotAppearance
    ) -> String {
        let baseName = "Onboarding-\(content.rawValue)-\(language.rawValue)"
        switch appearance {
        case .light:
            return baseName
        case .dark:
            return "\(baseName)-dark"
        }
    }
}

private struct OnboardingScreenshotCard<Screen: View>: View {
    let screen: Screen

    init(@ViewBuilder screen: () -> Screen) {
        self.screen = screen()
    }

    var body: some View {
        screen
            .aspectRatio(1206.0 / 2622.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
    }
}

enum OnboardingScreenshotLanguage: String, CaseIterable, Equatable, Sendable {
    case english = "en"
    case japanese = "ja"

    static func resolve(locale: Locale) -> Self {
        locale.language.languageCode?.identifier == japanese.rawValue
            ? .japanese
            : .english
    }
}

enum OnboardingScreenshotAppearance: String, CaseIterable, Equatable, Sendable {
    case light
    case dark

    static func resolve(colorScheme: ColorScheme) -> Self {
        colorScheme == .dark ? .dark : .light
    }
}
#endif
