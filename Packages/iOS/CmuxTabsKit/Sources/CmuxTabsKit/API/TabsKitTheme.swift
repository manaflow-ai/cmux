#if os(iOS)
import SwiftUI
import UIKit

/// Colors, metrics and springs for the whole kit. The defaults are measured
/// Mobile Safari values (iOS 26/27 compact layout, 402 x 874 pt reference
/// screen) with one accent; override any of them and inject the theme with
/// `.tabsKitTheme(_:)`.
public struct TabsKitTheme: Sendable {
    public var colors: Colors
    public var metrics: Metrics
    public var motion: Motion

    public init(colors: Colors = Colors(), metrics: Metrics = Metrics(), motion: Motion = Motion()) {
        self.colors = colors
        self.metrics = metrics
        self.motion = motion
    }

    /// Safari color tokens.
    public struct Colors: Sendable {
        public var label = Colors.pair(0x000000, 0xFFFFFF)
        public var glyphDisabled = Colors.pair(0xC5C5C7, 0x5B5B5D)
        public var secondaryLabel = Colors.pair(0x3C3C43, 0xEBEBF5, lightAlpha: 0.6, darkAlpha: 0.6)
        /// Behind pages (start page, swipe gaps, placeholder cards).
        public var pageBackground = Colors.pair(0xF2F2F7, 0x000000)
        /// Tab grid wallpaper, top and bottom of the gradient.
        public var overviewTop = Colors.pair(0xECDFD3, 0x1A1918)
        public var overviewBottom = Colors.pair(0xD2D3DB, 0x0B0B0D)
        /// Card close circle: #F2F2F7 over a white card, white 8 % over a
        /// dark one; the cross is mid gray.
        /// Dark values from a device screenshot (opaque #3E3E3F, cross #A7A7A9).
        public var cardCloseFill = Colors.pair(0xF2F2F7, 0x3E3E3F, lightAlpha: 0.94, darkAlpha: 1)
        public var cardCloseGlyph = Colors.pair(0x7E7E83, 0xA7A7A9)
        public var separator = Colors.pair(0x3C3C43, 0x545458, lightAlpha: 0.18, darkAlpha: 0.5)
        /// The one hue: progress line and the Done button (Safari's #0088FF;
        /// cmux uses its highlight blue).
        public var accent = Colors.pair(0x0869CB, 0x0869CB)

        public init() {}

        /// A light/dark pair from hex values.
        public static func pair(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
            Color(uiColor: UIColor { trait in
                let hex = trait.userInterfaceStyle == .dark ? dark : light
                let a = trait.userInterfaceStyle == .dark ? darkAlpha : lightAlpha
                return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                               blue: CGFloat(hex & 0xFF) / 255, alpha: a)
            })
        }
    }

    /// Toolbar, menu and card metrics (points; 402 pt wide reference screen).
    /// The tab grid's geometry is fixed by the measured layout (OverviewLayout).
    public struct Metrics: Sendable {
        /// Toolbar side inset (34).
        public var sideInset: CGFloat = 34
        /// Glass circle diameter and bar height (48).
        public var control: CGFloat = 48
        /// Gap between circles and the capsule (8).
        public var gap: CGFloat = 8
        /// Extra width of the back pill when forward history exists.
        public var forwardExtra: CGFloat = 40
        /// Address label size, expanded (17 pt medium).
        public var urlFont: CGFloat = 17
        /// Collapsed label scale (69 -> 51 pt wide).
        public var collapsedScale: CGFloat = 0.74
        /// Collapsed pill: text + 2 x 19 pt, 32 high, 14 pt above the screen bottom.
        public var pillPadding: CGFloat = 19
        public var pillHeight: CGFloat = 32
        public var pillBottom: CGFloat = 14
        /// Progress line along the capsule bottom.
        public var progressHeight: CGFloat = 2
        /// Finger travel down that collapses the bar and up that expands it.
        public var collapseThreshold: CGFloat = 15
        public var expandThreshold: CGFloat = 6
        /// Editing with a software keyboard: 8 pt insets and gap above the keyboard.
        public var editInset: CGFloat = 8
        /// Display corner radius for full-screen pages in zooms and swipes.
        public var screenRadius: CGFloat = 55
        /// Card close button (22 pt circle) and the grid's top controls (36 pt).
        public var cardClose: CGFloat = 22
        public var overviewTopControl: CGFloat = 36
        public var titleRow: CGFloat = 23
        /// Page menu.
        public var menuWidth: CGFloat = 250
        public var menuRadius: CGFloat = 32
        public var menuRow: CGFloat = 42
        public var menuGroupGap: CGFloat = 21

        public init() {}
    }

    /// Springs fitted to the Safari reference recordings. The tab zoom's
    /// springs live with its state machine (`ZoomSpring`).
    public struct Motion: Sendable {
        /// Toolbar collapse on scroll down (0.39 / 0.86).
        public var collapse = Animation.spring(response: 0.39, dampingFraction: 0.86)
        /// Expand on scroll up (0.385 / 0.880).
        public var expandScroll = Animation.spring(response: 0.385, dampingFraction: 0.88)
        /// Expand on tapping the pill (0.390 / 0.879).
        public var expandTap = Animation.spring(response: 0.39, dampingFraction: 0.88)
        /// Side buttons: gone by about 105 ms on collapse; on expand they
        /// start about 90 ms in and ease out.
        public var sideOut = Animation.linear(duration: 0.10)
        public var sideIn = Animation.easeOut(duration: 0.23).delay(0.09)
        /// Address field rides with the keyboard.
        public var keyboard = Animation.spring(response: 0.35, dampingFraction: 1)
        /// Go: field back into the toolbar.
        public var editEnd = Animation.spring(response: 0.30, dampingFraction: 1)
        /// Page menu glass morph.
        public var menu = Animation.spring(response: 0.40, dampingFraction: 0.78)
        /// Card reflow after closing a tab (0.427 / 0.89, x and y).
        /// Card reflow after a close: Safari's own reflow curve replayed
        /// (`SafariCurve.reflow`; fitted springs stayed 1-2 frames off).
        public var reflow = Animation(SafariCurveAnimation(curve: .reflow))
        /// Toolbar swipe snap.
        public var swipe = Animation.spring(response: 0.40, dampingFraction: 0.9)

        public init() {}

        /// Reduce Motion swaps every spatial animation for a short crossfade.
        @MainActor public func resolve(_ animation: Animation) -> Animation {
            UIAccessibility.isReduceMotionEnabled ? .easeInOut(duration: 0.18) : animation
        }
    }
}

extension EnvironmentValues {
    /// The kit's theme (`.tabsKitTheme(_:)`).
    @Entry public var tabsKitTheme = TabsKitTheme()
}

extension View {
    /// Sets the theme of the `TabsView` below.
    public func tabsKitTheme(_ theme: TabsKitTheme) -> some View {
        environment(\.tabsKitTheme, theme)
    }
}
#endif
