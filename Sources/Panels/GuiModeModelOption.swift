import Foundation

/// Describes one GUI Mode model and the reasoning levels it accepts.
struct GuiModeModelOption: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let reasoningEfforts: [String]
}
