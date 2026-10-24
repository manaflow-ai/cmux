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
        webKitFeaturesByKey[key]
    }
}

/// Every `_WKFeature` of the running WebKit by its key, read once per process: the set is fixed
/// for a loaded WebKit, and every page and browser tab sets its render rate when it is made, so
/// reading `_features` (several hundred objects, a KVC read each) there cost the main thread inside
/// the user's action. Empty when this WebKit has no `_features` SPI. Main-actor isolated (the
/// module default), as every caller is.
private let webKitFeaturesByKey: [String: NSObject] = {
    let selector = NSSelectorFromString("_features")
    let type: AnyObject = WKPreferences.self
    guard type.responds(to: selector), let features = type.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return [:] }
    var byKey: [String: NSObject] = [:]
    for feature in features {
        if let key = feature.value(forKey: "key") as? String, byKey[key] == nil { byKey[key] = feature }
    }
    return byKey
}()

/// WebKit's page render rate (one path for browser tabs, React pages and
/// the agent pane). WebKit renders near 60 fps by default; full rate follows
/// the display (120 Hz on ProMotion). Browser tabs and cmux pages are made at
/// full rate and keep it: in Low Power Mode WebKit halves every page's rate by
/// itself, live (its LowPowerMode throttling reason). Only the agent pane
/// changes its own rate later (its adaptive and debug `capped` rates).
public struct WebKitRenderRate {
    public init() {}
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
