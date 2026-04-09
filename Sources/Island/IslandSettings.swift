// Sources/Island/IslandSettings.swift

import Foundation

/// Preference keys and defaults for the cmux Island module.
///
/// Matches the existing `*Settings` struct pattern in cmux (see
/// `NotificationBadgeSettings`, `CursorIntegrationSettings`, etc.).
enum IslandSettings {
    /// UserDefaults / @AppStorage key for the island enable toggle.
    static let enabledKey: String = "island.enabled"

    /// Default is OFF per the MVP design.
    static let defaultEnabled: Bool = false
}
