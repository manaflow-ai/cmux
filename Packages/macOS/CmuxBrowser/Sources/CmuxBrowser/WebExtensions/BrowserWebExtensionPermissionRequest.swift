public import Foundation

/// An optional permission request that requires an explicit user decision.
public struct BrowserWebExtensionPermissionRequest: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let profileID: UUID
    public let managementID: String
    public let extensionName: String
    public let permissions: [String]
    public let hosts: [String]

    public init(
        id: UUID = UUID(),
        profileID: UUID,
        managementID: String,
        extensionName: String,
        permissions: [String] = [],
        hosts: [String] = []
    ) {
        self.id = id
        self.profileID = profileID
        self.managementID = managementID
        self.extensionName = extensionName
        self.permissions = permissions.sorted()
        self.hosts = hosts.sorted()
    }
}
