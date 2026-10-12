import Foundation

/// Deletes a group; its tabs stay in place. Result: `{group, surfaces}`.
public struct UngroupTabGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "ungroup-tab-group"
    public static let requiredCapability: String? = DaemonCapabilities.shared.tabGroups
    public var group: TabGroupID
    public init(group: TabGroupID) { self.group = group }

    @available(*, deprecated, message: "ungroup-tab-group takes no transaction; use init(group:)")
    public init(group: TabGroupID, transaction: ClientTransactionID?) { self.init(group: group) }
}

/// Closes every member placement in one commit. Terminal processes keep
/// running, as with any closed view, unless `endTerminals` (`batch-close-v1`)
/// ends each member terminal left with no tab and not kept in the same
/// commit; a linked saved group remains. Result: `{group, closed}`.
public struct CloseTabGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "close-tab-group"
    public static let requiredCapability: String? = DaemonCapabilities.shared.tabGroups
    public var group: TabGroupID
    public var endTerminals: Bool
    public init(group: TabGroupID, endTerminals: Bool = false) {
        self.group = group
        self.endTerminals = endTerminals
    }

    enum CodingKeys: String, CodingKey { case group, endTerminals }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(group, forKey: .group)
        if endTerminals { try c.encode(true, forKey: .endTerminals) }
    }

    @available(*, deprecated, message: "close-tab-group takes no transaction; use init(group:)")
    public init(group: TabGroupID, transaction: ClientTransactionID?) { self.init(group: group) }
}
