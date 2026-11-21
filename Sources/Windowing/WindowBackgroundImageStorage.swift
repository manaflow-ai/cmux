import CmuxFoundation
import SwiftUI

/// Reads the window background image settings from `UserDefaults.standard`
/// and refreshes the view that holds it whenever one of them changes, from
/// Settings or from `cmux.json`.
struct WindowBackgroundImageStorage: DynamicProperty {
    @AppStorage(WindowBackgroundImageSettings.pathDefaultsKey)
    private var path = ""
    @AppStorage(WindowBackgroundImageSettings.opacityDefaultsKey)
    private var opacity = WindowBackgroundImageSettings.defaultOpacity
    @AppStorage(WindowBackgroundImageSettings.fitDefaultsKey)
    private var fitRawValue = WindowBackgroundImageSettings.defaultFit.rawValue

    /// The current settings, sanitized the same way as every other reader.
    var settings: WindowBackgroundImageSettings {
        WindowBackgroundImageSettings(
            path: path,
            opacity: opacity,
            fit: WindowBackgroundImageFit(rawValue: fitRawValue) ?? WindowBackgroundImageSettings.defaultFit
        )
    }
}
