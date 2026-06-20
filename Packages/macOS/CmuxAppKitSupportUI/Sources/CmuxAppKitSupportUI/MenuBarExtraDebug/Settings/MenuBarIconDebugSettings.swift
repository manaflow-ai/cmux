#if canImport(AppKit)

public import Foundation

/// `@AppStorage`-backed tuning for the menu-bar icon's unread badge.
///
/// Owns the `UserDefaults` keys, defaults, value clamping, and copy-payload
/// formatting shared by the Menu Bar Extra Debug panel (which edits these keys
/// live) and the app target's production menu-bar icon renderer (which reads the
/// resolved ``MenuBarBadgeRenderConfig`` on every redraw). Co-locating the keys
/// here keeps one source of truth for the wire-frozen defaults names.
// Faithful byte-identical lift of the app target's caseless-enum settings
// namespace; the Defaults keys and payload format are frozen, so converting this
// to an instance/receiver shape is a separate behavior-adjacent modernization
// tracked as refactor residue. lint:allow namespace-type
public enum MenuBarIconDebugSettings {
    public static let previewEnabledKey = "menubarDebugPreviewEnabled"
    public static let previewCountKey = "menubarDebugPreviewCount"
    public static let badgeRectXKey = "menubarDebugBadgeRectX"
    public static let badgeRectYKey = "menubarDebugBadgeRectY"
    public static let badgeRectWidthKey = "menubarDebugBadgeRectWidth"
    public static let badgeRectHeightKey = "menubarDebugBadgeRectHeight"
    public static let singleDigitFontSizeKey = "menubarDebugSingleDigitFontSize"
    public static let multiDigitFontSizeKey = "menubarDebugMultiDigitFontSize"
    public static let singleDigitYOffsetKey = "menubarDebugSingleDigitYOffset"
    public static let multiDigitYOffsetKey = "menubarDebugMultiDigitYOffset"
    public static let singleDigitXAdjustKey = "menubarDebugSingleDigitXAdjust"
    public static let legacySingleDigitXAdjustKey = "menubarDebugTextRectXAdjust"
    public static let multiDigitXAdjustKey = "menubarDebugMultiDigitXAdjust"
    public static let textRectWidthAdjustKey = "menubarDebugTextRectWidthAdjust"

    public static let defaultBadgeRect = NSRect(x: 5.38, y: 6.43, width: 10.75, height: 11.58)
    public static let defaultSingleDigitFontSize: CGFloat = 6.7
    public static let defaultMultiDigitFontSize: CGFloat = 6.7
    public static let defaultSingleDigitYOffset: CGFloat = 0.6
    public static let defaultMultiDigitYOffset: CGFloat = 0.6
    public static let defaultSingleDigitXAdjust: CGFloat = -1.1
    public static let defaultMultiDigitXAdjust: CGFloat = 2.42
    public static let defaultTextRectWidthAdjust: CGFloat = 1.8

    public static func displayedUnreadCount(actualUnreadCount: Int, defaults: UserDefaults = .standard) -> Int {
        guard defaults.bool(forKey: previewEnabledKey) else { return actualUnreadCount }
        let value = defaults.integer(forKey: previewCountKey)
        return max(0, min(value, 99))
    }

    public static func badgeRenderConfig(defaults: UserDefaults = .standard) -> MenuBarBadgeRenderConfig {
        let x = value(defaults, key: badgeRectXKey, fallback: defaultBadgeRect.origin.x, range: 0...20)
        let y = value(defaults, key: badgeRectYKey, fallback: defaultBadgeRect.origin.y, range: 0...20)
        let width = value(defaults, key: badgeRectWidthKey, fallback: defaultBadgeRect.width, range: 4...14)
        let height = value(defaults, key: badgeRectHeightKey, fallback: defaultBadgeRect.height, range: 4...14)
        let singleFont = value(defaults, key: singleDigitFontSizeKey, fallback: defaultSingleDigitFontSize, range: 6...14)
        let multiFont = value(defaults, key: multiDigitFontSizeKey, fallback: defaultMultiDigitFontSize, range: 6...14)
        let singleY = value(defaults, key: singleDigitYOffsetKey, fallback: defaultSingleDigitYOffset, range: -3...4)
        let multiY = value(defaults, key: multiDigitYOffsetKey, fallback: defaultMultiDigitYOffset, range: -3...4)
        let singleX = value(
            defaults,
            key: singleDigitXAdjustKey,
            legacyKey: legacySingleDigitXAdjustKey,
            fallback: defaultSingleDigitXAdjust,
            range: -4...4
        )
        let multiX = value(defaults, key: multiDigitXAdjustKey, fallback: defaultMultiDigitXAdjust, range: -4...4)
        let widthAdjust = value(defaults, key: textRectWidthAdjustKey, fallback: defaultTextRectWidthAdjust, range: -3...5)

        return MenuBarBadgeRenderConfig(
            badgeRect: NSRect(x: x, y: y, width: width, height: height),
            singleDigitFontSize: singleFont,
            multiDigitFontSize: multiFont,
            singleDigitYOffset: singleY,
            multiDigitYOffset: multiY,
            singleDigitXAdjust: singleX,
            multiDigitXAdjust: multiX,
            textRectWidthAdjust: widthAdjust
        )
    }

    public static func copyPayload(defaults: UserDefaults = .standard) -> String {
        let config = badgeRenderConfig(defaults: defaults)
        let previewEnabled = defaults.bool(forKey: previewEnabledKey)
        let previewCount = max(0, min(defaults.integer(forKey: previewCountKey), 99))
        return """
        menubarDebugPreviewEnabled=\(previewEnabled)
        menubarDebugPreviewCount=\(previewCount)
        menubarDebugBadgeRectX=\(String(format: "%.2f", config.badgeRect.origin.x))
        menubarDebugBadgeRectY=\(String(format: "%.2f", config.badgeRect.origin.y))
        menubarDebugBadgeRectWidth=\(String(format: "%.2f", config.badgeRect.width))
        menubarDebugBadgeRectHeight=\(String(format: "%.2f", config.badgeRect.height))
        menubarDebugSingleDigitFontSize=\(String(format: "%.2f", config.singleDigitFontSize))
        menubarDebugMultiDigitFontSize=\(String(format: "%.2f", config.multiDigitFontSize))
        menubarDebugSingleDigitYOffset=\(String(format: "%.2f", config.singleDigitYOffset))
        menubarDebugMultiDigitYOffset=\(String(format: "%.2f", config.multiDigitYOffset))
        menubarDebugSingleDigitXAdjust=\(String(format: "%.2f", config.singleDigitXAdjust))
        menubarDebugMultiDigitXAdjust=\(String(format: "%.2f", config.multiDigitXAdjust))
        menubarDebugTextRectWidthAdjust=\(String(format: "%.2f", config.textRectWidthAdjust))
        """
    }

    private static func value(
        _ defaults: UserDefaults,
        key: String,
        legacyKey: String? = nil,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        if let parsed = parse(defaults.object(forKey: key), fallback: fallback, range: range) {
            return parsed
        }
        if let legacyKey, let parsed = parse(defaults.object(forKey: legacyKey), fallback: fallback, range: range) {
            return parsed
        }
        return fallback
    }

    private static func parse(
        _ object: Any?,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat? {
        guard let number = object as? NSNumber else {
            return nil
        }
        let candidate = CGFloat(number.doubleValue)
        guard candidate.isFinite else { return fallback }
        return max(range.lowerBound, min(candidate, range.upperBound))
    }
}

#endif
