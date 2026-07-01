import Foundation

struct CmuxNoteReadResult: Equatable, Sendable {
    var note: CmuxNoteRecord
    var path: String
    var content: String
}
