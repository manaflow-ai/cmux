import Foundation

extension PutSessionRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var session: SessionRecord
        public var created: Bool
    }
}

extension ImportSessionOrganizationRequest {
    public struct Group: Encodable, Sendable, Hashable {
        public var id: WorkspaceGroupID
        public var name: String
        public var color: String?
        public var collapsed: Bool
        public init(id: WorkspaceGroupID, name: String, color: String?, collapsed: Bool) {
            self.id = id
            self.name = name
            self.color = color
            self.collapsed = collapsed
        }
    }
    public struct Workspace: Encodable, Sendable, Hashable {
        public var workspaceKey: WorkspaceKey
        public var group: WorkspaceGroupID?
        public init(workspaceKey: WorkspaceKey, group: WorkspaceGroupID?) {
            self.workspaceKey = workspaceKey
            self.group = group
        }
    }
    public struct Response: Decodable, Sendable, Equatable {
        public var imported: Bool
    }
}
