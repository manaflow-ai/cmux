import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Platform-resolved system colors used by the cross-platform shell chrome.
///
/// Bridges UIKit/AppKit semantic colors into SwiftUI `Color`s so the same view
/// code renders correct system backgrounds and separators on iOS and macOS.
struct PlatformPalette {
    private init() {}

    /// The system window/background color.
    static var systemBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.white
        #endif
    }

    /// The system separator color.
    static var separator: Color {
        #if os(iOS)
        Color(uiColor: .separator)
        #elseif os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color.gray
        #endif
    }

}
