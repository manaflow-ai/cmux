import AppKit
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSocketControl
import CmuxSettings
import CmuxSettingsUI
import CmuxUpdaterUI
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers


// MARK: - Command Palette Settings
enum CommandPaletteRenameSelectionSettings {
    static let selectAllOnFocusKey = "commandPalette.renameSelectAllOnFocus"
    static let defaultSelectAllOnFocus = true

    static func selectAllOnFocusEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: selectAllOnFocusKey) == nil {
            return defaultSelectAllOnFocus
        }
        return defaults.bool(forKey: selectAllOnFocusKey)
    }
}

enum CommandPaletteSwitcherSearchSettings {
    static let searchAllSurfacesKey = "commandPalette.switcherSearchAllSurfaces"
    static let defaultSearchAllSurfaces = false

    private static func searchAllSurfacesEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: searchAllSurfacesKey) == nil {
            return defaultSearchAllSurfaces
        }
        return defaults.bool(forKey: searchAllSurfacesKey)
    }
}

