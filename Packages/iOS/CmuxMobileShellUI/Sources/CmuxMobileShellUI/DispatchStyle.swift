import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Visual vocabulary of the Dispatch work order: monospaced caps field labels,
/// hairline rules, and a paper-like card. Everything else on the surface uses
/// the app's semantic colors so the document reads as part of cmux.
enum DispatchStyle {
    /// Height of the launch stub button.
    static let stubButtonHeight: CGFloat = 52
    /// Corner radius of the document card.
    static let cardCornerRadius: CGFloat = 16
    /// Horizontal content padding inside the card.
    static let cardPadding: CGFloat = 20

    static var screenBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var cardBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var hairline: Color {
        #if canImport(UIKit)
        Color(uiColor: .separator)
        #else
        Color(nsColor: .separatorColor)
        #endif
    }

    /// The high-contrast ink used for the launch stub and selected agent pill.
    static var ink: Color { .primary }

    /// Text color on top of `ink` fills.
    static var inkReversed: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var stampApproved: Color { .green }
    static var stampRejected: Color { .red }

    /// Monospaced caps micro-label ("BRIEF", "PROJECT", …).
    static var fieldLabelFont: Font {
        .system(.caption2, design: .monospaced).weight(.semibold)
    }

    static let fieldLabelTracking: CGFloat = 1.4

    /// Monospaced value text (paths, summary line, serial).
    static var monoValueFont: Font {
        .system(.footnote, design: .monospaced)
    }

    static var monoCaptionFont: Font {
        .system(.caption2, design: .monospaced)
    }

    /// The launch stub's label.
    static var stubFont: Font {
        .system(.callout, design: .monospaced).weight(.semibold)
    }
}

/// Horizontal-shake effect for inline validation nudges; retriggers whenever
/// the generation changes so a repeated invalid attempt shakes again.
struct DispatchShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = sin(animatableData * .pi * 3) * 6
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}
