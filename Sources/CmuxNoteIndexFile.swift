import Foundation

struct CmuxNoteIndexFile: Codable, Sendable {
    var version: Int
    var notes: [CmuxNoteRecord]
}
