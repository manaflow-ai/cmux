import Foundation

/// One accepted daemon tab, including the durable owner and revision of its name.
struct CloudVMTabState: Hashable, Codable, Sendable {
    var id: String
    var paneID: String
    var name: String?
    var index: Int
    var focused: Bool
    var contentKind: String
    var contentID: String
    var nameAuthority: CloudTabNameAuthority? = nil
}
