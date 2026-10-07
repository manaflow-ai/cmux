import Foundation

/// A directory a phone may reach on this Mac (c4-files.md section 3): the
/// inbox or a workspace's directory. `MobileFilePolicy` canonicalizes it and
/// drops it when it is home, an ancestor of home, outside home or protected.
public struct MobileFileRoot: Hashable, Sendable {
    /// Stable id (`inbox`, or the workspace id).
    public var id: String
    public var name: String
    public var url: URL
    /// Uploads with `dest.kind = path` may land here.
    public var writable: Bool

    public init(id: String, name: String, url: URL, writable: Bool) {
        self.id = id
        self.name = name
        self.url = url
        self.writable = writable
    }
}
