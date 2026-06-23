import SwiftUI

/// Environment flag for split-tree surfaces that need the terminal's real
/// AppKit host inside the SwiftUI tree instead of the window-level portal.
///
/// Zoomable splits use this so magnification scales the terminal content as
/// part of the packed split tree.
private struct DirectTerminalHostingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var cmuxDirectTerminalHosting: Bool {
        get { self[DirectTerminalHostingKey.self] }
        set { self[DirectTerminalHostingKey.self] = newValue }
    }
}
