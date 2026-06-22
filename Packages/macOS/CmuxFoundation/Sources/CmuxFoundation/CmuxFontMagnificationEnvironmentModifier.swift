public import SwiftUI

private struct CmuxGlobalFontMagnificationPercentKey: EnvironmentKey {
    static var defaultValue: Int { GlobalFontMagnification.storedPercent }
}

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

struct CmuxFontMagnificationEnvironmentModifier: ViewModifier {
    @AppStorage(GlobalFontMagnification.percentKey) private var percent = GlobalFontMagnification.defaultPercent

    func body(content: Content) -> some View {
        content.environment(\.cmuxGlobalFontMagnificationPercent, percent)
    }
}
