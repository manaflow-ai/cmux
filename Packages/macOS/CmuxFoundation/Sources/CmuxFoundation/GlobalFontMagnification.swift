public import AppKit
public import Foundation
public import SwiftUI

/// App-wide magnification for cmux-owned chrome and terminal configuration.
///
/// Stored as an integer percent (100 = default, 150 = 1.5x, 200 = 2x).
/// SwiftUI call sites should use ``View/cmuxFont(size:weight:design:monospacedDigit:)``
/// or ``View/cmuxFont(_:weight:design:)``. AppKit call sites should use the
/// `GlobalFontMagnification` font helpers and reapply them from
/// ``didChangeNotification`` via ``GlobalFontMagnificationChangeObserver``.
public enum GlobalFontMagnification {
    public static let percentKey = "globalFontMagnificationPercent"

    public static let defaultPercent: Int = 100
    public static let minimumPercent: Int = 50
    /// Capped at 200% so cmux fixed-size chrome does not clip or overflow.
    public static let maximumPercent: Int = 200
    public static let stepPercent: Int = 10

    public static let didChangeNotification = Notification.Name("cmux.globalFontMagnification.didChange")

    /// Raw percent stored in UserDefaults. If the key is unset, treat as 100%.
    /// Accepts numeric storage and string-encoded integers so values written
    /// from `defaults write` resolve cleanly.
    public static var storedPercent: Int {
        let raw = UserDefaults.standard.object(forKey: percentKey)
        let resolved: Int
        if let number = raw as? NSNumber {
            resolved = number.intValue
        } else if let string = raw as? String, let parsed = Int(string) {
            resolved = parsed
        } else {
            resolved = defaultPercent
        }
        return clamp(resolved)
    }

    /// Multiplier (1.0 for 100%, 1.5 for 150%, etc.).
    public static var scale: CGFloat {
        CGFloat(storedPercent) / CGFloat(defaultPercent)
    }

    public static var isDefault: Bool { storedPercent == defaultPercent }

    /// Scale a design-time point size by the current magnification.
    public static func scaled(_ base: CGFloat) -> CGFloat {
        max(1, base * scale)
    }

    public static func scaledSize(_ baseSize: CGFloat) -> CGFloat {
        scaled(baseSize)
    }

    public static func systemFont(ofSize baseSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: scaledSize(baseSize), weight: weight)
    }

    public static func monospacedSystemFont(ofSize baseSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: scaledSize(baseSize), weight: weight)
    }

    public static func monospacedDigitSystemFont(ofSize baseSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: scaledSize(baseSize), weight: weight)
    }

    public static func menuFont(ofSize baseSize: CGFloat = NSFont.systemFontSize) -> NSFont {
        NSFont.menuFont(ofSize: scaledSize(baseSize))
    }

    public static func font(name: String, size baseSize: CGFloat) -> NSFont? {
        NSFont(name: name, size: scaledSize(baseSize))
    }

    public static func clamp(_ percent: Int) -> Int {
        Swift.max(minimumPercent, Swift.min(maximumPercent, percent))
    }

    public static func setPercent(_ percent: Int) {
        UserDefaults.standard.set(clamp(percent), forKey: percentKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Restores the default magnification and posts the live-update notification.
    public static func resetToDefault() {
        UserDefaults.standard.set(defaultPercent, forKey: percentKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

public final class GlobalFontMagnificationChangeObserver {
    private let notificationCenter: NotificationCenter
    private var notificationObserver: NSObjectProtocol?

    public init(notificationCenter: NotificationCenter = .default, handler: @MainActor @escaping () -> Void) {
        self.notificationCenter = notificationCenter
        notificationObserver = notificationCenter.addObserver(
            forName: GlobalFontMagnification.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
    }

    deinit {
        if let notificationObserver {
            notificationCenter.removeObserver(notificationObserver)
        }
    }
}

enum CmuxTextStyleMetrics {
    static func baseSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline: return 13
        case .subheadline: return 11
        case .body: return 13
        case .callout: return 12
        case .footnote: return 10
        case .caption: return 10
        case .caption2: return 9
        @unknown default: return 13
        }
    }

    static func baseWeight(for style: Font.TextStyle) -> Font.Weight {
        switch style {
        case .headline: return .semibold
        default: return .regular
        }
    }
}

struct CmuxFontModifier: ViewModifier {
    @AppStorage(GlobalFontMagnification.percentKey) private var percent: Int = GlobalFontMagnification.defaultPercent
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    var monospacedDigit: Bool = false

    func body(content: Content) -> some View {
        content.font(resolvedFont)
    }

    private var resolvedFont: Font {
        var font = Font.system(size: scaledSize, weight: weight, design: design)
        if monospacedDigit {
            font = font.monospacedDigit()
        }
        return font
    }

    private var scaledSize: CGFloat {
        let clamped = GlobalFontMagnification.clamp(percent)
        return max(1, baseSize * CGFloat(clamped) / CGFloat(GlobalFontMagnification.defaultPercent))
    }
}

public extension View {
    /// Apply a system font at `size` points, scaled by the global magnification.
    func cmuxFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(
            CmuxFontModifier(
                baseSize: size,
                weight: weight,
                design: design,
                monospacedDigit: monospacedDigit
            )
        )
    }

    /// Apply a text-style-sized system font, scaled by the global magnification.
    func cmuxFont(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(
            CmuxFontModifier(
                baseSize: CmuxTextStyleMetrics.baseSize(for: style),
                weight: weight ?? CmuxTextStyleMetrics.baseWeight(for: style),
                design: design,
                monospacedDigit: monospacedDigit
            )
        )
    }
}
