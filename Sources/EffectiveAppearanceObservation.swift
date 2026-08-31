import Foundation

/// Shared observation contract used by appearance observers that own a
/// Foundation/AppKit observation token.
protocol EffectiveAppearanceObservation: AnyObject {
    func invalidate()
}

extension NSKeyValueObservation: EffectiveAppearanceObservation {}
