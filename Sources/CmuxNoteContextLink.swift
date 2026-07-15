import Foundation

/// How a note relates to the surface/workspace context of a caller (e.g. the
/// terminal an agent runs `cmux note ...` from).
enum CmuxNoteContextLink: String, Codable, Sendable {
    case surface
    case workspace
}
