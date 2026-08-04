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
        OnboardingIPhoneScreenshotFrame(preferredHeight: preferredFrameHeight) {
            ZStack {
                Color(.systemBackground)
                if let screenshot {
                    Image(uiImage: screenshot)
                        .resizable()
                        .scaledToFit()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: preferredFrameHeight)
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

    private var preferredFrameHeight: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 360
        }
        return horizontalSizeClass == .regular ? 620 : 480
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
    let preferredHeight: CGFloat
    let screen: Screen
    private let metrics = OnboardingIPhoneScreenshotFrameMetrics()

    init(preferredHeight: CGFloat, @ViewBuilder screen: () -> Screen) {
        self.preferredHeight = preferredHeight
        self.screen = screen()
    }

    var body: some View {
        OnboardingIPhoneFrameLayout(
            preferredHeight: preferredHeight,
            metrics: metrics
        ) {
            ZStack {
                Color(.systemBackground)
                screen
            }
            .clipShape(screenShape)
            .overlay {
                screenShape.stroke(
                    Color.white.opacity(0.16),
                    lineWidth: 1
                )
            }
        }
        .background {
            OnboardingIPhoneShell(metrics: metrics)
        }
    }

    private var screenShape: OnboardingProportionalRoundedRectangle {
        OnboardingProportionalRoundedRectangle(
            cornerRadiusFraction: metrics.screenCornerRadiusFraction
        )
    }
}

private struct OnboardingIPhoneShell: View {
    let metrics: OnboardingIPhoneScreenshotFrameMetrics

    var body: some View {
        ZStack {
            OnboardingProportionalRoundedRectangle(
                cornerRadiusFraction: metrics.outerCornerRadiusFraction
            )
            .fill(aluminumRim)

            OnboardingInsetRoundedRectangle(
                insetFraction: metrics.glassInsetFraction,
                cornerRadiusFraction: metrics.glassCornerRadiusFraction
            )
            .fill(Color.black)

            OnboardingProportionalRoundedRectangle(
                cornerRadiusFraction: metrics.outerCornerRadiusFraction
            )
            .stroke(Color.white.opacity(0.34), lineWidth: 1)

            OnboardingInsetRoundedRectangle(
                insetFraction: metrics.glassInsetFraction,
                cornerRadiusFraction: metrics.glassCornerRadiusFraction
            )
            .stroke(Color.black.opacity(0.7), lineWidth: 1)
        }
    }

    private var aluminumRim: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(white: 0.72), location: 0),
                .init(color: Color(white: 0.28), location: 0.18),
                .init(color: Color(white: 0.12), location: 0.5),
                .init(color: Color(white: 0.42), location: 0.82),
                .init(color: Color(white: 0.68), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private struct OnboardingIPhoneFrameLayout: Layout {
    let preferredHeight: CGFloat
    let metrics: OnboardingIPhoneScreenshotFrameMetrics

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        precondition(
            subviews.count == 1,
            "OnboardingIPhoneFrameLayout requires exactly one screen subview"
        )
        let width = finite(proposal.width)
        let height = finite(proposal.height)

        if let width, let height {
            let fittedHeight = min(height, preferredHeight)
            let fittedWidth = min(
                width,
                fittedHeight * metrics.outerAspectRatio
            )
            return CGSize(
                width: fittedWidth,
                height: fittedWidth / metrics.outerAspectRatio
            )
        }
        if let width {
            let fittedHeight = min(
                preferredHeight,
                width / metrics.outerAspectRatio
            )
            return CGSize(
                width: fittedHeight * metrics.outerAspectRatio,
                height: fittedHeight
            )
        }
        let fittedHeight = min(height ?? preferredHeight, preferredHeight)
        return CGSize(
            width: fittedHeight * metrics.outerAspectRatio,
            height: fittedHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        precondition(
            subviews.count == 1,
            "OnboardingIPhoneFrameLayout requires exactly one screen subview"
        )
        guard let screen = subviews.first else { return }
        let horizontalInset = bounds.width
            * metrics.screenInsetFraction
        let screenWidth = max(0, bounds.width - horizontalInset * 2)
        let screenHeight = min(
            bounds.height,
            screenWidth / metrics.screenAspectRatio
        )
        screen.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(width: screenWidth, height: screenHeight)
        )
    }

    private func finite(_ dimension: CGFloat?) -> CGFloat? {
        guard let dimension, dimension.isFinite else { return nil }
        return max(0, dimension)
    }
}

private struct OnboardingProportionalRoundedRectangle: Shape {
    let cornerRadiusFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(
            cornerRadius: rect.width * cornerRadiusFraction,
            style: .continuous
        )
        .path(in: rect)
    }
}

private struct OnboardingInsetRoundedRectangle: Shape {
    let insetFraction: CGFloat
    let cornerRadiusFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let inset = rect.width * insetFraction
        let insetRect = rect.insetBy(dx: inset, dy: inset)
        return RoundedRectangle(
            cornerRadius: insetRect.width * cornerRadiusFraction,
            style: .continuous
        )
        .path(in: insetRect)
    }
}

private struct OnboardingIPhoneScreenshotFrameMetrics {
    // iPhone 17 Pro body, display, and outer-radius dimensions. Keeping the
    // shell styling proportional preserves the same curves at every size.
    let bodyWidth: CGFloat = 71.9
    let bodyHeight: CGFloat = 150
    let displayWidth: CGFloat = 1206
    let displayHeight: CGFloat = 2622
    let outerCornerRadius: CGFloat = 12
    let glassInset: CGFloat = 0.18

    var outerAspectRatio: CGFloat { bodyWidth / bodyHeight }
    var screenAspectRatio: CGFloat { displayWidth / displayHeight }
    var outerCornerRadiusFraction: CGFloat { outerCornerRadius / bodyWidth }
    var glassInsetFraction: CGFloat { glassInset / bodyWidth }
    var screenInsetFraction: CGFloat {
        (1 - screenAspectRatio / outerAspectRatio)
            / (2 * (1 - screenAspectRatio))
    }
    var glassCornerRadiusFraction: CGFloat {
        (outerCornerRadiusFraction - glassInsetFraction)
            / (1 - 2 * glassInsetFraction)
    }
    var screenCornerRadiusFraction: CGFloat {
        (outerCornerRadiusFraction - screenInsetFraction)
            / (1 - 2 * screenInsetFraction)
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
