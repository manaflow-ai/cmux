#if os(iOS)
import Foundation
import SwiftUI
import UIKit

/// Full-height Simulator captures from the production workspace list and
/// notification feed preview entrypoints, presented inside an iPhone frame.
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
        OnboardingIPhoneScreenshotFrame {
            ZStack {
                Color(.systemBackground)
                if let screenshot {
                    Image(uiImage: screenshot)
                        .resizable()
                        .scaledToFit()
                }
            }
        }
        .frame(height: frameHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(content.accessibilityIdentifier)
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

    private var frameHeight: CGFloat {
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
        let cacheKey = resourceName as NSString
        if let cachedImage = screenshotCache.object(forKey: cacheKey) {
            return cachedImage
        }

        guard let loaded = await loadImage(resourceName: resourceName) else {
            assertionFailure("Missing onboarding screenshot: \(resourceName).png")
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
        cache.countLimit = Content.allCases.count
            * OnboardingScreenshotLanguage.allCases.count
            * OnboardingScreenshotAppearance.allCases.count
        return cache
    }()

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

private struct OnboardingIPhoneScreenshotFrame<Screen: View>: View {
    let screen: Screen

    init(@ViewBuilder screen: () -> Screen) {
        self.screen = screen()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: OnboardingIPhoneScreenshotFrameMetrics.outerCornerRadius,
                style: .continuous
            )
            .fill(Color.black)

            ZStack {
                Color(.systemBackground)
                screen
                    .aspectRatio(
                        OnboardingIPhoneScreenshotFrameMetrics.screenAspectRatio,
                        contentMode: .fit
                    )
            }
            .clipShape(screenShape)
            .padding(8)

            screenShape
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                .padding(8)

            RoundedRectangle(
                cornerRadius: OnboardingIPhoneScreenshotFrameMetrics.outerCornerRadius,
                style: .continuous
            )
            .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            sideButton(height: 46)
                .offset(x: -3, y: -82)
        }
        .overlay(alignment: .leading) {
            sideButton(height: 62)
                .offset(x: -3, y: -12)
        }
        .overlay(alignment: .trailing) {
            sideButton(height: 86)
                .offset(x: 3, y: 34)
        }
        .aspectRatio(
            OnboardingIPhoneScreenshotFrameMetrics.outerAspectRatio,
            contentMode: .fit
        )
    }

    private var screenShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: OnboardingIPhoneScreenshotFrameMetrics.screenCornerRadius,
            style: .continuous
        )
    }

    private func sideButton(height: CGFloat) -> some View {
        Capsule()
            .fill(Color.black)
            .frame(width: 4, height: height)
    }
}

private enum OnboardingIPhoneScreenshotFrameMetrics {
    static let outerAspectRatio: CGFloat = 0.49
    static let screenAspectRatio: CGFloat = 1206 / 2622
    static let outerCornerRadius: CGFloat = 48
    static let screenCornerRadius: CGFloat = 40
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
