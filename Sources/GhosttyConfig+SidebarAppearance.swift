import Foundation
import AppKit


// MARK: - Sidebar Appearance
extension GhosttyConfig {
    mutating func resolveSidebarBackground(preferredColorScheme: ColorSchemePreference) {
        guard let raw = rawSidebarBackground else { return }

        let lightResolved = Self.resolveThemeName(from: raw, preferredColorScheme: .light)
        let darkResolved = Self.resolveThemeName(from: raw, preferredColorScheme: .dark)
        let hasDualMode = lightResolved != darkResolved

        if hasDualMode {
            sidebarBackgroundLight = NSColor(hex: lightResolved)
            sidebarBackgroundDark = NSColor(hex: darkResolved)
        }

        let resolved = Self.resolveThemeName(from: raw, preferredColorScheme: preferredColorScheme)
        if let color = NSColor(hex: resolved) {
            sidebarBackground = color
        }
    }

    func applySidebarAppearanceToUserDefaults() {
        guard rawSidebarBackground != nil else {
            if let opacity = sidebarTintOpacity {
                UserDefaults.standard.set(opacity, forKey: "sidebarTintOpacity")
            }
            return
        }

        let defaults = UserDefaults.standard

        if let light = sidebarBackgroundLight {
            defaults.set(light.hexString(), forKey: "sidebarTintHexLight")
        } else {
            defaults.removeObject(forKey: "sidebarTintHexLight")
        }
        if let dark = sidebarBackgroundDark {
            defaults.set(dark.hexString(), forKey: "sidebarTintHexDark")
        } else {
            defaults.removeObject(forKey: "sidebarTintHexDark")
        }
        if let color = sidebarBackground {
            defaults.set(color.hexString(), forKey: "sidebarTintHex")
        } else {
            defaults.removeObject(forKey: "sidebarTintHex")
        }
        if let opacity = sidebarTintOpacity {
            defaults.set(opacity, forKey: "sidebarTintOpacity")
        }
    }

}
