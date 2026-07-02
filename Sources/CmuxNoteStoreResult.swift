import Foundation

struct CmuxNoteStoreResult: Equatable, Sendable {
    var note: CmuxNoteRecord
    var path: String
    var created: Bool
    var attached: Bool
}
