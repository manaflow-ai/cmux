import Foundation

/// The push-notification fields a mute rule can match against, extracted from
/// an incoming APNs payload (`title` plus the optional `cmux.workspaceGroupId`,
/// `cmux.workspaceGroupName`, and `cmux.macDeviceId` fields).
public struct MobilePushFilterCandidate: Equatable, Sendable {
    /// The push's visible title. `nil`/absent matches like an empty string.
    public let title: String?
    /// The Mac-local id of the workspace group the push came from, when sent.
    public let workspaceGroupId: String?
    /// The display name of that workspace group, when sent.
    public let workspaceGroupName: String?
    /// The sending Mac's stable device id, when sent.
    public let macDeviceId: String?

    /// Creates a candidate from an incoming push's fields.
    public init(
        title: String? = nil,
        workspaceGroupId: String? = nil,
        workspaceGroupName: String? = nil,
        macDeviceId: String? = nil
    ) {
        self.title = title
        self.workspaceGroupId = workspaceGroupId
        self.workspaceGroupName = workspaceGroupName
        self.macDeviceId = macDeviceId
    }
}
