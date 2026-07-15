import Foundation

struct NoteSupportListEntry: Equatable {
    let slug: String
    let path: String
    let sizeBytes: Int64
    let mtime: Date
}
