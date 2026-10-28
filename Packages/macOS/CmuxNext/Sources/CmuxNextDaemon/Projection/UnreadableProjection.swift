import Foundation

/// A store refused to write a personal projection it could not read: a newer build saved it at another
/// schema, or in a shape this build does not decode. Writing over it would erase that build's state, so
/// the store shows an empty document and refuses every write until a later load reads one it understands.
public struct UnreadableProjection: Error, Sendable, Equatable {
    /// The projection's subject key.
    public let subject: String
    /// The schema the stored document says it has.
    public let schemaVersion: UInt32
    /// The schema this build reads and writes.
    public let readableSchemaVersion: UInt32

    public init(subject: String, schemaVersion: UInt32, readableSchemaVersion: UInt32) {
        self.subject = subject
        self.schemaVersion = schemaVersion
        self.readableSchemaVersion = readableSchemaVersion
    }
}
