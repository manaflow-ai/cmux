import Foundation

/// One accepted daemon tab, including the durable owner and revision of its name.
public struct CloudVMTabState: Hashable, Codable, Sendable {
    public var id: String
    public var paneID: String
    public var name: String?
    public var index: Int
    public var focused: Bool
    public var contentKind: String
    public var contentID: String
    public var nameAuthority: CloudTabNameAuthority? = nil

    public init(
        id: String,
        paneID: String,
        name: String? = nil,
        index: Int,
        focused: Bool,
        contentKind: String,
        contentID: String,
        nameAuthority: CloudTabNameAuthority? = nil
    ) {
        self.id = id
        self.paneID = paneID
        self.name = name
        self.index = index
        self.focused = focused
        self.contentKind = contentKind
        self.contentID = contentID
        self.nameAuthority = nameAuthority
    }
}

