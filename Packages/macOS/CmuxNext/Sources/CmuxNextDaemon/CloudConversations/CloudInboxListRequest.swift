import Foundation

/// `cloud-inbox-list`: the account inbox (UserDO `inbox.list`).

/// `cloud-inbox-list`: the account inbox (UserDO `inbox.list`).
public struct CloudInboxListRequest: DaemonRequest {
    public typealias Response = CloudInboxList
    public static let command = "cloud-inbox-list"
    public static let maxLimit = 200
    public var limit: Int?
    public var includeArchived: Bool?
    public init(limit: Int? = nil, includeArchived: Bool? = nil) {
        self.limit = limit.map { min(max($0, 1), Self.maxLimit) }
        self.includeArchived = includeArchived
    }
}
