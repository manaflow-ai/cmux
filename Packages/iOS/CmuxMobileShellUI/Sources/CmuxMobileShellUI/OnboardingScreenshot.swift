#if os(iOS)
import Foundation
import SwiftUI
import UIKit

/// Full-height Simulator captures from the production workspace list and
/// notification feed preview entrypoints, presented inside the same iPhone
/// product frame used by the App Store screenshot pipeline.
struct OnboardingScreenshot: View {
    enum Content: String, CaseIterable {
        case workspaces
        case notifications
        case push

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
    @State private var deviceFrame: UIImage?
    @State private var screenMask: UIImage?
    @State private var screenshot: UIImage?

    var body: some View {
        OnboardingIPhoneScreenshotFrame(
            preferredHeight: preferredFrameHeight,
            deviceFrame: deviceFrame,
            screenMask: screenMask
        ) {
            ZStack {
                Color(.systemBackground)
                if let screenshot {
                    Image(uiImage: screenshot)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: preferredFrameHeight, alignment: .top)
        .opacity(imagesAreReady ? 1 : 0)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(
            imagesAreReady
                ? content.accessibilityIdentifier
                : "MobileOnboardingScreenshot-loading"
        )
        .task(id: resourceName) {
            screenshot = nil
            deviceFrame = nil
            screenMask = nil
            let loadedScreenshot = await Self.image(
                content: content,
                language: language,
                appearance: appearance
            )
            let loadedDeviceFrame = await Self.deviceFrameImage(appearance: appearance)
            let loadedScreenMask = await Self.screenMaskImage()
            guard !Task.isCancelled else { return }
            screenshot = loadedScreenshot
            deviceFrame = loadedDeviceFrame
            screenMask = loadedScreenMask
        }
    }

    private var imagesAreReady: Bool {
        screenshot != nil && deviceFrame != nil && screenMask != nil
    }

    private var preferredFrameHeight: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 360
        }
        return horizontalSizeClass == .regular ? 700 : 560
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
        // The push capture is a real iPhone Lock Screen photographed once: the
        // notification and inline reply it shows are live device output, so a
        // single asset serves every language and appearance until per-locale
        // captures are staged.
        if content == .push {
            return "Onboarding-push"
        }
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
    let deviceFrame: UIImage?
    let screenMask: UIImage?
    let screen: Screen
    private let metrics = OnboardingIPhoneProductFrameMetrics()

    init(
        preferredHeight: CGFloat,
        deviceFrame: UIImage?,
        screenMask: UIImage?,
        @ViewBuilder screen: () -> Screen
    ) {
        self.preferredHeight = preferredHeight
        self.deviceFrame = deviceFrame
        self.screenMask = screenMask
        self.screen = screen()
    }

    var body: some View {
        OnboardingIPhoneFrameLayout(
            preferredHeight: preferredHeight,
            metrics: metrics
        ) {
            // The mask asset is dilated a few pixels along its contour so the
            // screen tucks under the opaque bezel ring (no page-background
            // bleed at the seam) while staying inside the screen rectangle:
            // a scale transform here once lifted the mask's top corners past
            // the frame outline as visible tabs.
            OnboardingMaskedDeviceScreen(mask: screenMask) {
                screen
            }
            OnboardingDeviceFrameImage(image: deviceFrame)
        }
    }
}

private struct OnboardingMaskedDeviceScreen<Screen: View>: View {
    let mask: UIImage?
    let screen: Screen

    init(mask: UIImage?, @ViewBuilder screen: () -> Screen) {
        self.mask = mask
        self.screen = screen()
    }

    var body: some View {
        screen.mask {
            if let mask {
                Image(uiImage: mask)
                    .resizable()
            } else {
                Color.clear
            }
        }
    }
}

private struct OnboardingDeviceFrameImage: View {
    let image: UIImage?

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        } else {
            Color.clear
        }
    }
}

private struct OnboardingIPhoneFrameLayout: Layout {
    let preferredHeight: CGFloat
    let metrics: OnboardingIPhoneProductFrameMetrics

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        precondition(
            subviews.count == 2,
            "OnboardingIPhoneFrameLayout requires a screen and product frame"
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
            subviews.count == 2,
            "OnboardingIPhoneFrameLayout requires a screen and product frame"
        )
        guard let screen = subviews.first,
              let deviceFrame = subviews.last else { return }
        screen.place(
            at: CGPoint(
                x: bounds.minX + bounds.width * metrics.screenOriginX,
                y: bounds.minY + bounds.height * metrics.screenOriginY
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: bounds.width * metrics.screenWidth,
                height: bounds.height * metrics.screenHeight
            )
        )
        deviceFrame.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: bounds.width,
                height: bounds.height
            )
        )
    }

    private func finite(_ dimension: CGFloat?) -> CGFloat? {
        guard let dimension, dimension.isFinite else { return nil }
        return max(0, dimension)
    }
}

private struct OnboardingIPhoneProductFrameMetrics {
    // Pixel geometry from Apple iPhone 17 Pro Max Silver.png, shared with the
    // App Store screenshot composer in ios/fastlane/frame_assets.
    let frameWidth: CGFloat = 1470
    let frameHeight: CGFloat = 3000
    let screenX: CGFloat = 75
    let screenY: CGFloat = 66
    let screenPixelWidth: CGFloat = 1320
    let screenPixelHeight: CGFloat = 2868

    var outerAspectRatio: CGFloat { frameWidth / frameHeight }
    var screenOriginX: CGFloat { screenX / frameWidth }
    var screenOriginY: CGFloat { screenY / frameHeight }
    var screenWidth: CGFloat { screenPixelWidth / frameWidth }
    var screenHeight: CGFloat { screenPixelHeight / frameHeight }
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
