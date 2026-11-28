public import Foundation

/// The roles of the `cmux` binary on a server (server.md section 5).
public nonisolated enum ServerRole: String, Sendable, Equatable, Codable, CaseIterable {
    case session, link, apps, postgres, browser, automations, health, updater
}

public nonisolated enum ServerRoleState: String, Sendable, Equatable, Codable {
    case on, off, starting, failed, unavailable
}

public nonisolated struct ServerRoleStatus: Sendable, Equatable {
    public var role: ServerRole
    public var state: ServerRoleState

    public init(_ role: ServerRole, _ state: ServerRoleState) {
        self.role = role
        self.state = state
    }
}
