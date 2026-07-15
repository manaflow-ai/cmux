import CmuxCommandPalette
import AppKit
import Foundation
import SwiftUI

// `CommandPaletteContextKeys` now lives in the CmuxCommandPalette package. Notes
// is an app-layer feature, so its key is layered on here as an extension
// (mirroring the typed terminalOpenTargetAvailable overload in the app).
extension CommandPaletteContextKeys {
    /// Whether the Notes beta surface is enabled.
    static let notesBetaEnabled = CommandPaletteContextKeys(rawValue: "notes.betaEnabled")
}
