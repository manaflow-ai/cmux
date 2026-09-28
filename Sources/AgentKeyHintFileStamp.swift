import Foundation

/// A file's modification date and size, to notice when it changes.
struct AgentKeyHintFileStamp: Equatable, Sendable {
    var modificationDate: Date?
    var size: Int?
}
