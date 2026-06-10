#if DEBUG
import AppKit
import SwiftUI

// MARK: - Visual Style
enum FeedButtonDebugVisualStyle: String, CaseIterable, Identifiable {
    case solid
    case glass
    case standardGlass
    case standardTintedGlass
    case nativeGlass
    case nativeProminentGlass
    case liquid
    case halo
    case command
    case commandLight
    case outline
    case flat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .solid:
            return String(localized: "feed.buttonDebug.style.solid", defaultValue: "Solid")
        case .glass:
            return String(localized: "feed.buttonDebug.style.glass", defaultValue: "Raycast Glass")
        case .standardGlass:
            return String(localized: "feed.buttonDebug.style.standardGlass", defaultValue: "Standard Glass")
        case .standardTintedGlass:
            return String(localized: "feed.buttonDebug.style.standardTintedGlass", defaultValue: "Standard Tinted Glass")
        case .nativeGlass:
            return String(localized: "feed.buttonDebug.style.nativeGlass", defaultValue: "Native Glass")
        case .nativeProminentGlass:
            return String(localized: "feed.buttonDebug.style.nativeProminentGlass", defaultValue: "Prominent Glass")
        case .liquid:
            return String(localized: "feed.buttonDebug.style.liquid", defaultValue: "Liquid")
        case .halo:
            return String(localized: "feed.buttonDebug.style.halo", defaultValue: "Halo")
        case .command:
            return String(localized: "feed.buttonDebug.style.command", defaultValue: "Command")
        case .commandLight:
            return String(localized: "feed.buttonDebug.style.commandLight", defaultValue: "Command Light")
        case .outline:
            return String(localized: "feed.buttonDebug.style.outline", defaultValue: "Outline")
        case .flat:
            return String(localized: "feed.buttonDebug.style.flat", defaultValue: "Flat")
        }
    }
}

#endif
