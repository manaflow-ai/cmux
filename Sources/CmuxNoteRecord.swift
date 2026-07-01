import Foundation

struct CmuxNoteRecord: Codable, Equatable, Sendable {
    var id: String
    var slug: String
    var title: String
    var bodyPath: String
    var attachments: [CmuxNoteAttachment]
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
}
