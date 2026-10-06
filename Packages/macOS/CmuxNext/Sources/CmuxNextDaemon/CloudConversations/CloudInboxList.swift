import Foundation


/// `cloud-inbox-list` data. `revision` is the owner's opaque read revision.
public struct CloudInboxList: Decodable, Sendable, Equatable {
    public var entries: [CloudInboxEntry]
    public var revision: JSONValue?

    public init(entries: [CloudInboxEntry], revision: JSONValue? = nil) {
        self.entries = entries
        self.revision = revision
    }
}
