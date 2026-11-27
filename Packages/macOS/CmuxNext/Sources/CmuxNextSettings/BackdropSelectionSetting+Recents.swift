public import Foundation
import CmuxNextDesign

/// `appearance.backgroundRecents` (schemas/settings/source/appearance.json): the backgrounds shown
/// before, newest first. The daemon's settings write records it (cmux-config schema/backdrop.rs
/// record_recent); the app only validates and reads it.
extension BackdropSelectionSetting {
    /// At most this many recents (cmux-config RECENTS_CAP).
    public static let recentsCap = 8

    /// Whether a value is valid for `appearance.backgroundRecents`: an array of at most
    /// ``recentsCap`` different background values.
    static func acceptsRecents(_ value: JSONValue) -> Bool {
        SettingsRust.answer("backdrop.accepts", ["kind": .string("recents"), "value": value])["valid"]?.boolValue ?? false
    }

    /// The valid recents in `root`, newest first.
    public static func recents(in root: JSONValue) -> [String] {
        SettingsRust.answer("backdrop.recents", ["root": root.keeping([recentsPath])])["recents"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// The background Switch to Previous Background goes to: the newest recent that is not the
    /// current one (cmux-config previous_background).
    public static func previous(in root: JSONValue) -> String? {
        SettingsRust.answer("backdrop.previous", ["root": root.keeping([recentsPath, configPath])])["value"]?.stringValue
    }
}

/// How Recent Backgrounds… and the window menu name one recent background.
public nonisolated struct BackdropRecentLabel: Sendable, Hashable {
    public let value: String
    public let title: String
    /// An SF Symbol: a folder for a rotating folder, a shuffle for the paintings, a photo otherwise.
    public let symbol: String
}

extension BackdropSelectionSetting {
    /// A recent's row: a rotating folder by its folder's name, a picture or mode by the title the
    /// Background setting gives it (None, Shuffle Paintings, a painting, your own image by name).
    public static func recentLabel(_ raw: String) -> BackdropRecentLabel {
        if let path = folderPath(raw) {
            return BackdropRecentLabel(value: raw, title: (path as NSString).lastPathComponent, symbol: "folder")
        }
        let title = SettingsSchema.descriptor(for: configPath)?
            .paletteOptions(current: .string(raw), themeColors: []).first(where: \.isCurrent)?.title
        let symbol = switch raw {
        case dailyID: "shuffle"
        case "none": "circle.slash"
        case BackdropSelection.desktopID: "desktopcomputer"
        default: "photo"
        }
        return BackdropRecentLabel(value: raw, title: title ?? raw, symbol: symbol)
    }
}
