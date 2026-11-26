public import SwiftUI

/// Adds cmux font magnification values to SwiftUI environment lookups.
public extension EnvironmentValues {
    /// The current clamped global font magnification percent.
    ///
    /// cmux scene roots should inject this value with
    /// ``View/cmuxFontMagnificationEnvironment()`` so repeated row labels can
    /// read a pure environment value instead of each subscribing to
    /// `UserDefaults`.
    var cmuxGlobalFontMagnificationPercent: Int {
        get { self[CmuxGlobalFontMagnificationPercentKey.self] }
        set { self[CmuxGlobalFontMagnificationPercentKey.self] = GlobalFontMagnification.clamp(newValue) }
    }
}
