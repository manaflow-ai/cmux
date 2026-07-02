import Foundation

struct CmuxNoteWriteResult: Equatable, Sendable {
    var note: CmuxNoteRecord
    var path: String
    var sizeBytes: Int64
}
