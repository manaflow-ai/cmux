import AppKit
import Foundation

/// Display and navigation metadata for one loaded CEF extension popup.
struct CEFExtensionAction: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let popupURL: URL
}
