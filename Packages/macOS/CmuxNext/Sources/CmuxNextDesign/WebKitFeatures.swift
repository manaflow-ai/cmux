public import Foundation
import ObjectiveC
public import WebKit

/// WebKit's runtime features (the Feature Flags list in Safari's Develop
/// menu), through the `_features` and `_setEnabled:forFeature:` SPI. Every
/// call checks that the running WebKit has the SPI and the feature, and does
/// nothing otherwise.
public extension WKPreferences {
    /// Turns the feature named `key` on or off; false when this WebKit has
    /// no such feature or SPI.
    @discardableResult
    func setWebKitFeature(_ key: String, enabled: Bool) -> Bool {
        let selector = NSSelectorFromString("_setEnabled:forFeature:")
        guard let feature = Self.webKitFeature(key), let method = class_getInstanceMethod(WKPreferences.self, selector) else { return false }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(method_getImplementation(method), to: SetEnabled.self)(self, selector, enabled, feature)
        return true
    }

    /// Whether the feature named `key` is on; nil when this WebKit has no
    /// such feature or SPI.
    func isWebKitFeatureEnabled(_ key: String) -> Bool? {
        let selector = NSSelectorFromString("_isEnabledForFeature:")
        guard let feature = Self.webKitFeature(key), let method = class_getInstanceMethod(WKPreferences.self, selector) else { return nil }
        typealias IsEnabled = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: IsEnabled.self)(self, selector, feature)
    }

    private static func webKitFeature(_ key: String) -> NSObject? {
        let selector = NSSelectorFromString("_features")
        let type: AnyObject = WKPreferences.self
        guard type.responds(to: selector), let features = type.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return nil }
        return features.first { $0.value(forKey: "key") as? String == key }
    }
}

/// WebKit's page render rate (one path for browser tabs, React pages and
/// the agent pane). WebKit renders near 60 fps by default; full rate follows
/// the display (120 Hz on ProMotion).
public enum WebKitRenderRate {
    /// WebKit's feature that renders a page at the display-rate divisor nearest 60 fps.
    public static let near60FPSFeature = "PreferPageRenderingUpdatesNear60FPSEnabled"

    @MainActor private static var reportedMissingFeature = false

    /// Sets `preferences` to render at the display's full rate, or near
    /// 60 fps. A WebKit without the feature keeps its default; that is
    /// logged once, never fatal.
    @MainActor @discardableResult
    public static func apply(fullRate: Bool, to preferences: WKPreferences) -> Bool {
        if preferences.setWebKitFeature(near60FPSFeature, enabled: !fullRate) { return true }
        if !reportedMissingFeature {
            reportedMissingFeature = true
            NSLog("cmux: WebKit has no %@ feature; pages keep WebKit's default render rate", near60FPSFeature)
        }
        return false
    }
}
