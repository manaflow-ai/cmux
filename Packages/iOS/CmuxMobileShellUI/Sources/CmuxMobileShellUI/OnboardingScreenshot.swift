#if os(iOS)
import Foundation
import SwiftUI
import UIKit

/// Cropped presentation of full-screen Simulator captures from the production
/// workspace list and notification feed preview entrypoints.
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
    @Environment(\.locale) private var locale
    @State private var screenshot: UIImage?

    var body: some View {
        Group {
            if let screenshot {
                Image(uiImage: screenshot)
                    .resizable()
            } else {
                Color.clear
            }
        }
            .aspectRatio(contentMode: .fill)
            .frame(maxWidth: .infinity)
            .offset(y: content.cropYOffset)
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
        appearance: OnboardingScreenshotAppearance = .light
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

private extension OnboardingScreenshot.Content {
    var cropYOffset: CGFloat {
        switch self {
        case .workspaces:
            0
        case .notifications:
            -140
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
