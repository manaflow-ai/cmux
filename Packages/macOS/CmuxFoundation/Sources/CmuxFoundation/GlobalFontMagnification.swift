public import AppKit
public import Foundation

/// App-wide magnification for cmux-owned chrome and terminal configuration.
///
/// Stored as an integer percent (100 = default, 150 = 1.5x, 200 = 2x).
/// SwiftUI call sites should use ``View/cmuxFont(size:weight:design:monospacedDigit:)``
/// or ``View/cmuxFont(_:weight:design:)``. AppKit call sites should use the
/// `GlobalFontMagnification` font helpers and reapply them from
/// ``didChangeNotification`` via ``GlobalFontMagnificationChangeObserver``.
public struct GlobalFontMagnification {
    private let userDefaults: UserDefaults
    private let notificationCenter: NotificationCenter

    /// Creates a font magnification helper backed by injectable storage.
    ///
    /// - Parameters:
    ///   - userDefaults: The defaults domain used for persisted magnification.
    ///   - notificationCenter: The center that receives live-update notifications.
    public init(userDefaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.userDefaults = userDefaults
        self.notificationCenter = notificationCenter
    }

    /// UserDefaults key storing the global font magnification percent.
    public static let percentKey = "globalFontMagnificationPercent"

    /// Default magnification percent.
    public static let defaultPercent: Int = 100
    /// Minimum supported magnification percent.
    public static let minimumPercent: Int = 50
    /// Capped at 200% so cmux fixed-size chrome does not clip or overflow.
    public static let maximumPercent: Int = 200
    /// Percent increment used by settings UI and schema validation.
    public static let stepPercent: Int = 10

    /// Notification posted after the global font magnification percent changes.
    public static let didChangeNotification = Notification.Name("cmux.globalFontMagnification.didChange")

    /// Raw percent stored in UserDefaults. If the key is unset, treat as 100%.
    /// Accepts numeric storage and string-encoded integers so values written
    /// from `defaults write` resolve cleanly.
    public var storedPercent: Int {
        let raw = userDefaults.object(forKey: Self.percentKey)
        let resolved: Int
        if let number = raw as? NSNumber {
            resolved = number.intValue
        } else if let string = raw as? String, let parsed = Int(string) {
            resolved = parsed
        } else {
            resolved = Self.defaultPercent
        }
        return Self.clamp(resolved)
    }

    /// Multiplier (1.0 for 100%, 1.5 for 150%, etc.).
    public var scale: CGFloat {
        CGFloat(storedPercent) / CGFloat(Self.defaultPercent)
    }

    /// Whether the current stored percent is the default magnification.
    public var isDefault: Bool { storedPercent == Self.defaultPercent }

    /// Scale a design-time point size by the current magnification.
    public func scaled(_ base: CGFloat) -> CGFloat {
        max(1, base * scale)
    }

    /// Scales a design-time point size by the current magnification.
    ///
    /// - Parameter baseSize: The unscaled design point size.
    /// - Returns: A point size clamped to at least 1 point.
    public func scaledSize(_ baseSize: CGFloat) -> CGFloat {
        scaled(baseSize)
    }

    /// Creates a magnified AppKit system font.
    ///
    /// - Parameters:
    ///   - baseSize: The unscaled design point size.
    ///   - weight: The AppKit system font weight.
    /// - Returns: A system font at the magnified point size.
    public func systemFont(ofSize baseSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: scaledSize(baseSize), weight: weight)
    }

    /// Creates a magnified AppKit monospaced system font.
    ///
    /// - Parameters:
    ///   - baseSize: The unscaled design point size.
    ///   - weight: The AppKit system font weight.
    /// - Returns: A monospaced system font at the magnified point size.
    public func monospacedSystemFont(ofSize baseSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: scaledSize(baseSize), weight: weight)
    }

    /// Creates a magnified AppKit system font with monospaced digits.
    ///
    /// - Parameters:
    ///   - baseSize: The unscaled design point size.
    ///   - weight: The AppKit system font weight.
    /// - Returns: A monospaced-digit system font at the magnified point size.
    public func monospacedDigitSystemFont(ofSize baseSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: scaledSize(baseSize), weight: weight)
    }

    /// Creates a magnified AppKit menu font.
    ///
    /// - Parameter baseSize: The unscaled design point size.
    /// - Returns: A menu font at the magnified point size.
    public func menuFont(ofSize baseSize: CGFloat = NSFont.systemFontSize) -> NSFont {
        NSFont.menuFont(ofSize: scaledSize(baseSize))
    }

    /// Creates a magnified named AppKit font.
    ///
    /// - Parameters:
    ///   - name: The AppKit font name.
    ///   - baseSize: The unscaled design point size.
    /// - Returns: A named font at the magnified point size, or `nil` if unavailable.
    public func font(name: String, size baseSize: CGFloat) -> NSFont? {
        NSFont(name: name, size: scaledSize(baseSize))
    }

    /// Normalizes a requested magnification to the supported range and step.
    public static func clamp(_ percent: Int) -> Int {
        let bounded = Swift.max(minimumPercent, Swift.min(maximumPercent, percent))
        let stepped = Int((Double(bounded) / Double(stepPercent)).rounded()) * stepPercent
        return Swift.max(minimumPercent, Swift.min(maximumPercent, stepped))
    }

    /// Stores a new percent and posts the live-update notification.
    ///
    /// - Parameter percent: The requested percent; values outside the supported
    ///   range are clamped before storage.
    public func setPercent(_ percent: Int) {
        userDefaults.set(Self.clamp(percent), forKey: Self.percentKey)
        notificationCenter.post(name: Self.didChangeNotification, object: nil)
    }

    /// Restores the default magnification and posts the live-update notification.
    public func resetToDefault() {
        userDefaults.set(Self.defaultPercent, forKey: Self.percentKey)
        notificationCenter.post(name: Self.didChangeNotification, object: nil)
    }

    /// Raw percent stored in `UserDefaults.standard`.
    public static var storedPercent: Int {
        Self().storedPercent
    }

    /// Multiplier for the percent stored in `UserDefaults.standard`.
    public static var scale: CGFloat {
        Self().scale
    }

    /// Whether `UserDefaults.standard` stores the default magnification.
    public static var isDefault: Bool {
        Self().isDefault
    }

    /// Scale a design-time point size by the standard stored magnification.
    public static func scaled(_ base: CGFloat) -> CGFloat {
        Self().scaled(base)
    }

    /// Returns the multiplier for a magnification percent.
    ///
    /// - Parameter percent: The requested percent; values outside the supported
    ///   range are clamped before the multiplier is calculated.
    public static func scale(for percent: Int) -> CGFloat {
        CGFloat(clamp(percent)) / CGFloat(defaultPercent)
    }

    /// Scales a design-time point size by a specific magnification percent.
    ///
    /// - Parameters:
    ///   - baseSize: The unscaled design point size.
    ///   - percent: The requested percent; values outside the supported range
    ///     are clamped before scaling.
    /// - Returns: A point size clamped to at least 1 point.
    public static func scaledSize(_ baseSize: CGFloat, percent: Int) -> CGFloat {
        max(1, baseSize * scale(for: percent))
    }

    /// Scales a design-time point size by the standard stored magnification.
    ///
    /// - Parameter baseSize: The unscaled design point size.
    /// - Returns: A point size clamped to at least 1 point.
    public static func scaledSize(_ baseSize: CGFloat) -> CGFloat {
        Self().scaledSize(baseSize)
    }

    /// Creates a system font using the standard stored magnification.
    ///
    /// - Parameters:
    ///   - baseSize: The unscaled design point size.
    ///   - weight: The AppKit system font weight.
    /// - Returns: A system font at the magnified point size.
    public static func systemFont(ofSize baseSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        Self().systemFont(ofSize: baseSize, weight: weight)
    }

    /// Creates a monospaced system font using the standard stored magnification.
    ///
    /// - Parameters:
    ///   - baseSize: The unscaled design point size.
    ///   - weight: The AppKit system font weight.
    /// - Returns: A monospaced system font at the magnified point size.
    public static func monospacedSystemFont(ofSize baseSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        Self().monospacedSystemFont(ofSize: baseSize, weight: weight)
    }

    /// Creates a monospaced-digit system font using the standard stored magnification.
    ///
    /// - Parameters:
    ///   - baseSize: The unscaled design point size.
    ///   - weight: The AppKit system font weight.
    /// - Returns: A monospaced-digit system font at the magnified point size.
    public static func monospacedDigitSystemFont(ofSize baseSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        Self().monospacedDigitSystemFont(ofSize: baseSize, weight: weight)
    }

    /// Creates a menu font using the standard stored magnification.
    ///
    /// - Parameter baseSize: The unscaled design point size.
    /// - Returns: A menu font at the magnified point size.
    public static func menuFont(ofSize baseSize: CGFloat = NSFont.systemFontSize) -> NSFont {
        Self().menuFont(ofSize: baseSize)
    }

    /// Creates a named font using the standard stored magnification.
    ///
    /// - Parameters:
    ///   - name: The AppKit font name.
    ///   - baseSize: The unscaled design point size.
    /// - Returns: A named font at the magnified point size, or `nil` if unavailable.
    public static func font(name: String, size baseSize: CGFloat) -> NSFont? {
        Self().font(name: name, size: baseSize)
    }

    /// Stores a new standard percent and posts the live-update notification.
    ///
    /// - Parameter percent: The requested percent; values outside the supported
    ///   range are clamped before storage.
    public static func setPercent(_ percent: Int) {
        Self().setPercent(percent)
    }

    /// Restores the standard stored magnification and posts the live-update notification.
    public static func resetToDefault() {
        Self().resetToDefault()
    }
}
