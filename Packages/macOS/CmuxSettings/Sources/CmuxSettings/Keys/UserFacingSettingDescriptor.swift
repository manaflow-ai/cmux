import Foundation

/// Canonical user-facing metadata shared by Settings, settings search, and
/// ordinary Command Palette setting toggles.
///
/// Storage identity/defaults stay on ``DefaultsKey``; this descriptor owns
/// presentation and discovery metadata only. Complex settings can keep custom
/// UI and behavior while reusing this metadata where it applies.
public struct UserFacingSettingDescriptor: Sendable, Equatable {
    public enum ControlKind: Sendable, Equatable {
        case toggle
    }

    public struct CommandPaletteToggle: Sendable, Equatable {
        public let id: String
        public let keywords: [String]

        /// Creates palette metadata for one ordinary toggle setting.
        public init(id: String, keywords: [String]) {
            self.id = id
            self.keywords = keywords
        }
    }

    public let title: String
    public let sectionID: String
    public let searchID: String
    public let searchKeywords: [String]
    public let controlKind: ControlKind
    public let commandPaletteToggle: CommandPaletteToggle?

    /// Creates shared presentation metadata for one catalog-backed setting.
    public init(
        title: String,
        sectionID: String,
        searchID: String,
        searchKeywords: [String],
        controlKind: ControlKind,
        commandPaletteToggle: CommandPaletteToggle? = nil
    ) {
        self.title = title
        self.sectionID = sectionID
        self.searchID = searchID
        self.searchKeywords = searchKeywords
        self.controlKind = controlKind
        self.commandPaletteToggle = commandPaletteToggle
    }
}
