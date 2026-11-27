import Foundation

/// Typed Settings destination owned by the settings catalog.
///
/// Add cases here as catalog-backed user-facing settings migrate. UI packages
/// map this enum to their navigation type with an exhaustive switch, so a new
/// destination cannot silently become an invalid raw string.
public enum UserFacingSettingSection: String, Sendable, Equatable {
    case app
}

/// Canonical user-facing metadata shared by Settings, settings search, and
/// ordinary Command Palette setting toggles.
///
/// Storage identity/defaults stay on DefaultsKey; this descriptor owns
/// presentation and discovery metadata only. Complex settings can keep custom
/// UI and behavior while reusing this metadata where it applies.
public struct UserFacingSettingDescriptor: Sendable, Equatable {
    public struct CommandPaletteToggle: Sendable, Equatable {
        public let id: String
        public let keywords: [String]

        /// Creates palette metadata for one ordinary toggle setting.
        public init(id: String, keywords: [String]) {
            self.id = id
            self.keywords = keywords
        }
    }

    public struct Toggle: Sendable, Equatable {
        public let commandPalette: CommandPaletteToggle?

        /// Creates metadata for an ordinary toggle.
        ///
        /// Palette exposure is optional, but it can only be attached to a
        /// toggle payload, so incompatible control/palette combinations are
        /// unrepresentable.
        public init(commandPalette: CommandPaletteToggle? = nil) {
            self.commandPalette = commandPalette
        }
    }

    public enum Control: Sendable, Equatable {
        case toggle(Toggle)
    }

    public let title: String
    public let section: UserFacingSettingSection
    public let searchID: String
    public let searchKeywords: [String]
    public let control: Control

    /// Creates shared presentation metadata for one catalog-backed setting.
    public init(
        title: String,
        section: UserFacingSettingSection,
        searchID: String,
        searchKeywords: [String],
        control: Control
    ) {
        self.title = title
        self.section = section
        self.searchID = searchID
        self.searchKeywords = searchKeywords
        self.control = control
    }
}
