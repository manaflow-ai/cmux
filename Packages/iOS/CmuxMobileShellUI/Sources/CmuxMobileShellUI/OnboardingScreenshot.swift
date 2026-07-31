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
            return 420
        }
        return horizontalSizeClass == .regular ? 660 : 560
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
            .fill(titaniumRim)

            RoundedRectangle(
                cornerRadius: OnboardingIPhoneScreenshotFrameMetrics.glassCornerRadius,
                style: .continuous
            )
            .fill(Color.black)
            .padding(OnboardingIPhoneScreenshotFrameMetrics.rimWidth)

            ZStack {
                Color(.systemBackground)
                screen
                    .aspectRatio(
                        OnboardingIPhoneScreenshotFrameMetrics.screenAspectRatio,
                        contentMode: .fit
                    )
            }
            .clipShape(screenShape)
            .padding(OnboardingIPhoneScreenshotFrameMetrics.screenInset)

            screenShape
                .stroke(
                    Color.white.opacity(0.16),
                    lineWidth: 1
                )
                .padding(OnboardingIPhoneScreenshotFrameMetrics.screenInset)

            RoundedRectangle(
                cornerRadius: OnboardingIPhoneScreenshotFrameMetrics.outerCornerRadius,
                style: .continuous
            )
            .stroke(outerHighlight, lineWidth: 1)

            RoundedRectangle(
                cornerRadius: OnboardingIPhoneScreenshotFrameMetrics.outerCornerRadius,
                style: .continuous
            )
            .stroke(Color.black.opacity(0.42), lineWidth: 1)
            .padding(1)
        }
        .overlay(alignment: .top) {
            OnboardingDynamicIsland()
                .padding(.top, OnboardingIPhoneScreenshotFrameMetrics.dynamicIslandTopInset)
        }
        .overlay(alignment: .leading) {
            OnboardingIPhoneSideButton(height: 48, edge: .leading)
                .offset(x: -4, y: -104)
        }
        .overlay(alignment: .leading) {
            OnboardingIPhoneSideButton(height: 66, edge: .leading)
                .offset(x: -4, y: -24)
        }
        .overlay(alignment: .trailing) {
            OnboardingIPhoneSideButton(height: 96, edge: .trailing)
                .offset(x: 4, y: 48)
        }
        .aspectRatio(
            OnboardingIPhoneScreenshotFrameMetrics.outerAspectRatio,
            contentMode: .fit
        )
    }

    private var titaniumRim: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(white: 0.70), location: 0.00),
                .init(color: Color(white: 0.16), location: 0.06),
                .init(color: Color(white: 0.04), location: 0.48),
                .init(color: Color(white: 0.30), location: 0.94),
                .init(color: Color(white: 0.68), location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var outerHighlight: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.54),
                Color.white.opacity(0.06),
                Color.black.opacity(0.26),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var screenShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: OnboardingIPhoneScreenshotFrameMetrics.screenCornerRadius,
            style: .continuous
        )
    }
}

private enum OnboardingIPhoneScreenshotFrameMetrics {
    static let outerAspectRatio: CGFloat = 78.0 / 163.4
    static let screenAspectRatio: CGFloat = 1206 / 2622
    static let outerCornerRadius: CGFloat = 62
    static let glassCornerRadius: CGFloat = 58
    static let screenCornerRadius: CGFloat = 51
    static let rimWidth: CGFloat = 4
    static let screenInset: CGFloat = 9
    static let dynamicIslandTopInset: CGFloat = 15
}

private struct OnboardingDynamicIsland: View {
    var body: some View {
        Capsule()
            .fill(Color.black)
            .frame(width: 76, height: 22)
            .overlay(alignment: .trailing) {
                Circle()
                    .fill(cameraLensGradient)
                    .frame(width: 8, height: 8)
                    .padding(.trailing, 12)
            }
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            }
    }

    private var cameraLensGradient: RadialGradient {
        RadialGradient(
            colors: [
                Color(red: 0.05, green: 0.12, blue: 0.20),
                Color(red: 0.00, green: 0.03, blue: 0.07),
                Color.black,
            ],
            center: .center,
            startRadius: 1,
            endRadius: 5
        )
    }
}

private struct OnboardingIPhoneSideButton: View {
    enum Edge {
        case leading
        case trailing
    }

    let height: CGFloat
    let edge: Edge

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(buttonGradient)
            .frame(width: 4, height: height)
            .overlay(alignment: edge == .leading ? .leading : .trailing) {
                Rectangle()
                    .fill(Color.white.opacity(0.24))
                    .frame(width: 1)
                    .padding(.vertical, 3)
            }
    }

    private var buttonGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(white: 0.38),
                Color(white: 0.05),
                Color(white: 0.22),
            ],
            startPoint: edge == .leading ? .leading : .trailing,
            endPoint: edge == .leading ? .trailing : .leading
        )
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
