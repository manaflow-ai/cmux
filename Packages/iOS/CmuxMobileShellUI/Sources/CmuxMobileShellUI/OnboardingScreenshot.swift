#if os(iOS)
import Foundation
import SwiftUI
import UIKit

/// Cropped presentation of full-screen Simulator captures from the production
/// workspace list, notification feed, and terminal preview entrypoints.
struct OnboardingScreenshot: View {
    enum Content: String, CaseIterable {
        case workspaces
        case notifications
        case terminal

        var accessibilityIdentifier: String {
            "MobileOnboardingScreenshot-\(rawValue)"
        }
    }

    let content: Content
    let accessibilityLabel: String

    @Environment(\.locale) private var locale

    var body: some View {
        Image(uiImage: Self.image(content: content, language: language))
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(maxWidth: .infinity)
            .frame(height: 330, alignment: .top)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(content.accessibilityIdentifier)
    }

    private var language: OnboardingScreenshotLanguage {
        OnboardingScreenshotLanguage.resolve(locale: locale)
    }

    @MainActor
    static func image(
        content: Content,
        language: OnboardingScreenshotLanguage
    ) -> UIImage {
        let resourceName = resourceName(content: content, language: language)
        let cacheKey = resourceName as NSString
        if let cachedImage = screenshotCache.object(forKey: cacheKey) {
            return cachedImage
        }

        guard let url = Bundle.module.url(
            forResource: resourceName,
            withExtension: "png"
        ), let data = try? Data(contentsOf: url),
              let image = UIImage(data: data, scale: 3) else {
            assertionFailure("Missing onboarding screenshot: \(resourceName).png")
            return UIImage()
        }
        screenshotCache.setObject(image, forKey: cacheKey, cost: data.count)
        return image
    }

    @MainActor private static let screenshotCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = OnboardingStage.allCases.count
        return cache
    }()

    private static func resourceName(
        content: Content,
        language: OnboardingScreenshotLanguage
    ) -> String {
        "Onboarding-\(content.rawValue)-\(language.rawValue)"
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
#endif
