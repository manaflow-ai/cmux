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
        guard let feature = Self.webKitFeature(key), let spi = Self.privateMethod("_setEnabled:forFeature:") else { return false }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(spi.implementation, to: SetEnabled.self)(self, spi.selector, enabled, feature)
        return true
    }

    /// Whether the feature named `key` is on; nil when this WebKit has no
    /// such feature or SPI.
    func isWebKitFeatureEnabled(_ key: String) -> Bool? {
        guard let feature = Self.webKitFeature(key), let spi = Self.privateMethod("_isEnabledForFeature:") else { return nil }
        typealias IsEnabled = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(spi.implementation, to: IsEnabled.self)(self, spi.selector, feature)
    }

    /// WebKit's hidden-page throttling of these preferences; nil when this WebKit lacks one of its
    /// getters.
    var hiddenPageThrottling: WebKitHiddenPageThrottling? {
        guard let domTimers = privateFlag("_hiddenPageDOMTimerThrottlingEnabled"),
              let autoIncrease = privateFlag("_hiddenPageDOMTimerThrottlingAutoIncreases"),
              let suppression = privateFlag("_pageVisibilityBasedProcessSuppressionEnabled") else { return nil }
        return WebKitHiddenPageThrottling(domTimers: domTimers, domTimersAutoIncrease: autoIncrease, processSuppression: suppression)
    }

    /// Sets each hidden-page throttling preference this WebKit has to `throttling`'s value; a WebKit
    /// without one keeps its default. WebKit sends the page a preferences update only for a value
    /// that changed, so setting the same values again costs no update.
    ///
    /// - Returns: How many of the three this WebKit has.
    @discardableResult
    func setHiddenPageThrottling(_ throttling: WebKitHiddenPageThrottling) -> Int {
        let set = [
            setPrivateFlag("_setHiddenPageDOMTimerThrottlingEnabled:", throttling.domTimers),
            setPrivateFlag("_setHiddenPageDOMTimerThrottlingAutoIncreases:", throttling.domTimersAutoIncrease),
            setPrivateFlag("_setPageVisibilityBasedProcessSuppressionEnabled:", throttling.processSuppression),
        ]
        return set.filter { $0 }.count
    }

    private func privateFlag(_ getter: String) -> Bool? {
        guard let spi = Self.privateMethod(getter) else { return nil }
        typealias GetFlag = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(spi.implementation, to: GetFlag.self)(self, spi.selector)
    }

    private func setPrivateFlag(_ setter: String, _ value: Bool) -> Bool {
        guard let spi = Self.privateMethod(setter) else { return false }
        typealias SetFlag = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(spi.implementation, to: SetFlag.self)(self, spi.selector, value)
        return true
    }

    /// The instance method `name` of this WebKit's WKPreferences: the one dispatch site of its
    /// instance SPI. Nil when this WebKit has no such method.
    private static func privateMethod(_ name: String) -> (selector: Selector, implementation: IMP)? {
        // crash-allow: WebKit private selector, called only through the IMP class_getInstanceMethod found (no unknown-selector exception).
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(WKPreferences.self, selector) else { return nil }
        return (selector, method_getImplementation(method))
    }

    private static func webKitFeature(_ key: String) -> NSObject? {
        let selector = NSSelectorFromString("_features")
        let type: AnyObject = WKPreferences.self
        guard type.responds(to: selector), let features = type.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return nil }
        return features.first { $0.value(forKey: "key") as? String == key }
    }
}

/// WebKit's hidden-page throttling preferences (`WKPreferencesPrivate.h`), each acting only while the
/// page is hidden: its DOM timers are throttled, that throttle grows while it stays hidden, and its
/// web process may be suppressed (App Nap) while it shows no page. A frozen page has all three on
/// (``full``); its thaw gives the page back what it had (``WKPreferences/hiddenPageThrottling``).
public struct WebKitHiddenPageThrottling: Hashable, Sendable {
    /// `_hiddenPageDOMTimerThrottlingEnabled`.
    public var domTimers: Bool
    /// `_hiddenPageDOMTimerThrottlingAutoIncreases`.
    public var domTimersAutoIncrease: Bool
    /// `_pageVisibilityBasedProcessSuppressionEnabled`.
    public var processSuppression: Bool

    public init(domTimers: Bool, domTimersAutoIncrease: Bool, processSuppression: Bool) {
        self.domTimers = domTimers
        self.domTimersAutoIncrease = domTimersAutoIncrease
        self.processSuppression = processSuppression
    }

    /// Every one on: a frozen page's.
    public static let full = WebKitHiddenPageThrottling(domTimers: true, domTimersAutoIncrease: true, processSuppression: true)
    /// Every one off.
    public static let off = WebKitHiddenPageThrottling(domTimers: false, domTimersAutoIncrease: false, processSuppression: false)
}

/// WebKit's page render rate (one path for browser tabs, React pages and
/// the agent pane). WebKit renders near 60 fps by default; full rate follows
/// the display (120 Hz on ProMotion).
public struct WebKitRenderRate {
    public init() {}
    /// WebKit's feature that renders a page at the display-rate divisor nearest 60 fps.
    public static let near60FPSFeature = "PreferPageRenderingUpdatesNear60FPSEnabled"

    @MainActor private static var reportedMissingFeature = false

    /// Whether pages prefer the display's full rate: not under Energy Saver.
    public static func prefersFullRate(energySaver: Bool) -> Bool {
        !energySaver
    }

    /// The rate a page renders at on a display whose highest rate is
    /// `displayMaxFPS`: that rate, or under Energy Saver WebKit's default,
    /// the display-rate divisor nearest 60 fps at or above it (60 on 120 Hz,
    /// 80 on 160 Hz; a display at 60 Hz or less renders at its own rate).
    public static func framesPerSecond(energySaver: Bool, displayMaxFPS: Int) -> Int {
        guard !prefersFullRate(energySaver: energySaver), displayMaxFPS > 60 else { return displayMaxFPS }
        return displayMaxFPS / (displayMaxFPS / 60)
    }

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
