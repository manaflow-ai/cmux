import Foundation

/// One Settings gesture on Cloud environments (`cmux.settings.environments.run`).
public nonisolated struct CloudEnvironmentsRun: Codable, Equatable, Sendable {
    /// Refresh the list; Save (create, or edit with ``id``); Build; Delete.
    public enum Action: String, Codable, Sendable { case refresh, save, build, delete }
    public var action: Action
    public var id: String?
    public var name: String?
    public var repo: String?
    public var setupScript: String?

    private enum CodingKeys: String, CodingKey {
        case action, id, name, repo
        case setupScript = "setup_script"
    }

    public init(action: Action, id: String? = nil, name: String? = nil, repo: String? = nil, setupScript: String? = nil) {
        self.action = action
        self.id = id
        self.name = name
        self.repo = repo
        self.setupScript = setupScript
    }
}
