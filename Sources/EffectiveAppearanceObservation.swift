import Foundation

/// Shared observation contract used by appearance observers that own a
/// Foundation/AppKit observation token.
protocol EffectiveAppearanceObservation: AnyObject {
    func invalidate()
}

extension NSKeyValueObservation: EffectiveAppearanceObservation {}

/// Main-actor observation token for AppKit system-color changes.
@MainActor
protocol SystemColorsObservation: AnyObject {
    func invalidate()
}
