#if os(iOS)
import SwiftUI
import UIKit

/// Typography roles from SPEC section 2.2. Dynamic Type text styles only; mono
/// code scales relative to `.footnote`.
public struct CmuxMobileTypography: Sendable {
    public var screenTitle = Font.headline
    public var sidebarTitle = Font.title2.weight(.semibold)
    public var heroTitle = Font.title.weight(.bold)
    /// The welcome headline: a quiet serif display line (SPEC 5.2).
    public var welcomeTitle = Font.system(.title, design: .serif)
    /// The "cmux" wordmark beside the chevron at the top of the welcome.
    public var welcomeWordmark = Font.title2.weight(.semibold)
    public var sheetTitle = Font.title3.weight(.semibold)
    public var emptyTitle = Font.headline
    public var body = Font.body
    /// Extra line spacing for prose (`body` at 17 pt has a 28 pt pitch).
    public var bodyLineSpacing: CGFloat = 6
    public var rowTitle = Font.body
    public var rowSubtitle = Font.subheadline
    public var meta = Font.footnote
    public var chip = Font.subheadline.weight(.medium)
    public var cta = Font.headline
    public var toolRow = Font.subheadline
    public var codeBody = Font.system(.footnote, design: .monospaced)
    public var codeLabel = Font.footnote.weight(.medium)
    public var diffGutter = Font.system(.caption2, design: .monospaced)
    public var legal = Font.caption2
    public var codeDigit = Font.system(.title2, design: .monospaced).weight(.medium)

    public init() {}
}

/// Spacing, sizes and radii from SPEC section 2.3 (4 pt grid).
public struct CmuxMobileMetrics: Sendable {
    public var sideMargin: CGFloat = 20
    public var glassButton: CGFloat = 44
    public var glassSymbol: CGFloat = 17
    public var composerRadius: CGFloat = 24
    public var composerMinHeight: CGFloat = 96
    public var composerSideMargin: CGFloat = 12
    public var smallCircle: CGFloat = 36
    /// A mini working spinner's backing disc, kept clear of a control's main symbol.
    public var workingIndicatorBadge: CGFloat = 16
    public var ctaLargeHeight: CGFloat = 52
    /// The welcome's sign-in rows: their minimum height (they grow with
    /// Dynamic Type) and the gap between them.
    public var ctaWelcomeHeight: CGFloat = 50
    public var ctaWelcomeGap: CGFloat = 8
    public var ctaInlineHeight: CGFloat = 40
    public var ctaInlinePadding: CGFloat = 20
    public var sidebarCapsuleHeight: CGFloat = 48
    public var settingsRowHeight: CGFloat = 52
    public var settingsIconFrame: CGFloat = 22
    public var groupRadius: CGFloat = 26
    public var sidebarRowPitch: CGFloat = 48
    public var teamRowHeight: CGFloat = 60
    public var teamAvatar: CGFloat = 36
    public var teamAvatarRadius: CGFloat = 10
    public var selectedRowRadius: CGFloat = 14
    public var selectedRowInset: CGFloat = 10
    public var macDot: CGFloat = 7
    public var macDotSpacing: CGFloat = 4
    public var macDotLimit = 5
    public var cardRadius: CGFloat = 20
    public var inputHeight: CGFloat = 52
    public var inputRadius: CGFloat = 14
    public var codeBoxSize = CGSize(width: 48, height: 56)
    public var codeBoxRadius: CGFloat = 12
    public var codeBoxGap: CGFloat = 8
    /// The pushed card's corner radius while the sidebar is open.
    public var sidebarCardRadius: CGFloat = 44
    public var sidebarParallax: CGFloat = 40
    public var cardStrokeWidth: CGFloat = 0.5
    public var cardShadowRadius: CGFloat = 20
    public var cardShadowOpacity: Float = 0.3
    public var cardShadowOffset = CGSize(width: -4, height: 0)

    /// Compatibility names used by earlier shell code.
    public var gutter: CGFloat { sideMargin }

    public init() {}

    /// `min(360, max(300, round(screenWidth * 0.75)))` (SPEC 3.3).
    public func sidebarWidth(forScreenWidth width: CGFloat) -> CGFloat {
        min(360, max(300, (width * 0.75).rounded()))
    }
}

/// A spring expressed the way SPEC section 2.7 writes it.
public struct CmuxMobileSpring: Sendable, Hashable {
    public let duration: Double
    public let bounce: Double

    public init(duration: Double, bounce: Double) {
        self.duration = duration
        self.bounce = bounce
    }

    /// The SwiftUI animation.
    public var animation: Animation { .spring(duration: duration, bounce: bounce) }

    /// UIKit spring timing, carrying an initial velocity in units of the
    /// remaining distance per second (`UISpringTimingParameters` convention).
    public func timingParameters(initialVelocity: CGFloat = 0) -> UISpringTimingParameters {
        UISpringTimingParameters(dampingRatio: CGFloat(1 - bounce), initialVelocity: CGVector(dx: initialVelocity, dy: 0))
    }

    /// A property animator for this spring.
    @MainActor
    public func animator(initialVelocity: CGFloat = 0) -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(duration: duration, timingParameters: timingParameters(initialVelocity: initialVelocity))
    }
}

/// Motion tokens (SPEC 2.7). Reduce Motion swaps translation for `snap` crossfades.
public struct CmuxMobileMotion: Sendable {
    public var snap = CmuxMobileSpring(duration: 0.25, bounce: 0)
    public var smooth = CmuxMobileSpring(duration: 0.35, bounce: 0)
    public var snappy = CmuxMobileSpring(duration: 0.35, bounce: 0.12)
    public var drawer = CmuxMobileSpring(duration: 0.42, bounce: 0)
    public var gentle = CmuxMobileSpring(duration: 0.5, bounce: 0)
    public var springBack = CmuxMobileSpring(duration: 0.3, bounce: 0.3)
    /// Shake keyframes (x offsets) over `shakeDuration` seconds.
    public var shakeOffsets: [CGFloat] = [0, -8, 8, -6, 6, -3, 0]
    public var shakeDuration: Double = 0.4
    /// Shimmer sweep period.
    public var shimmerPeriod: Double = 1.6
    /// Delay before skeletons appear (no flash for fast loads).
    public var skeletonDelay: Duration = .milliseconds(250)
    /// Welcome button stagger.
    public var staggerStep: Double = 0.05

    /// Compatibility names used by earlier shell code.
    public var sidebar: Animation { drawer.animation }
    public var press: Animation { snap.animation }
    public var content: Animation { smooth.animation }

    public init() {}
}

/// Gated haptics (SPEC 2.6): off when the in-app "Haptic feedback" setting is
/// off or Low Power Mode is on. The system haptics switch applies automatically.
public final class CmuxMobileHaptics: Sendable {
    /// The `UserDefaults` key the Settings toggle writes.
    public let settingKey = "cmuxMobile.settings.hapticsEnabled"

    public init() {}

    public var isEnabled: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        return UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    /// Send, submit, approve.
    @MainActor public func impactLight() { impact(.light, intensity: 1) }
    /// Sidebar crossing its open threshold during a pan.
    @MainActor public func threshold() { impact(.light, intensity: 0.5) }
    /// Copy confirmations.
    @MainActor public func copy() { impact(.light, intensity: 0.7) }
    /// Team switch, segment and picker changes, stream start.
    @MainActor public func selection() {
        guard isEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    @MainActor public func success() { notify(.success) }
    @MainActor public func warning() { notify(.warning) }
    @MainActor public func error() { notify(.error) }

    @MainActor private func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: intensity)
    }

    @MainActor private func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

/// Legacy palette names, mapped onto the SPEC tokens.
public struct CmuxMobilePalette: Sendable {
    private let colors: CmuxMobileColors

    public init(colors: CmuxMobileColors = CmuxMobileColors()) {
        self.colors = colors
    }

    public var background: Color { colors.bg.color }
    public var groupedBackground: Color { colors.bgGrouped.color }
    public var secondaryText: Color { colors.label2.color }
    public var accent: Color { colors.accent.color }
    public var online: Color { colors.success.color }
    public var offline: Color { colors.offline.color }
    public var attention: Color { colors.warning.color }
    public var danger: Color { colors.danger.color }
}

/// The design system entry point: `CmuxMobileTheme.standard.colors.bg`.
public struct CmuxMobileTheme: Sendable {
    public var colors = CmuxMobileColors()
    public var type = CmuxMobileTypography()
    public var metrics = CmuxMobileMetrics()
    public var motion = CmuxMobileMotion()
    public let haptics = CmuxMobileHaptics()

    public var palette: CmuxMobilePalette { CmuxMobilePalette(colors: colors) }

    public init() {}

    public static let standard = CmuxMobileTheme()
}

extension View {
    /// Plays `feedback` on `trigger` changes only while haptics are enabled.
    public func cmuxMobileSensoryFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        sensoryFeedback(trigger: trigger) { _, _ in
            CmuxMobileTheme.standard.haptics.isEnabled ? feedback : nil
        }
    }

    /// Animates with `spring`, or a `snap` crossfade when Reduce Motion is on.
    public func cmuxMobileAnimation<V: Equatable>(_ spring: CmuxMobileSpring, value: V) -> some View {
        modifier(CmuxMobileReduceMotionAnimation(spring: spring, value: value))
    }
}

private struct CmuxMobileReduceMotionAnimation<V: Equatable>: ViewModifier {
    let spring: CmuxMobileSpring
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? CmuxMobileTheme.standard.motion.snap.animation : spring.animation, value: value)
    }
}
#endif
