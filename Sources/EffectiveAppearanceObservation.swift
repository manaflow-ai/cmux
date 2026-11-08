import Foundation

/// Shared observation contract used by appearance observers that KVO-watch
/// `NSApplication.effectiveAppearance`.
protocol EffectiveAppearanceObservation: AnyObject {
    func invalidate()
}

extension NSKeyValueObservation: EffectiveAppearanceObservation {}
