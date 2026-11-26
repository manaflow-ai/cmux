import CmuxNextWindowRules
import Foundation

/// What the Rust project rules read and answer (`onboarding_first_run_projects`, `_folders`,
/// `_rank`, `_recent`, `_complete`; cmux-window-rules `onboarding_first_run`): the session files'
/// folders and the probed dates out, the grouped, kept and ranked projects back. The file reads
/// and folder probes stay here; no rule does.
nonisolated enum ProjectRules {
    nonisolated struct Session: Encodable {
        var path: String
        var modified: Double
        var app: String
    }

    nonisolated struct Project: Codable {
        var path: String
        var sessions: Int
        var lastActive: Double?
        var apps: [String]
    }

    nonisolated struct Repository: Encodable {
        var path: String
        var modified: Double
    }

    private nonisolated struct GroupRequest: Encodable {
        var sessions: [Session]
        var repositories: [String]
    }

    private nonisolated struct FoldersRequest: Encodable {
        var home: String
        var agentHomes: [String]
        var paths: [String]
    }

    private nonisolated struct RankRequest: Encodable {
        var now: Double
        var projects: [Project]
    }

    private nonisolated struct RecentRequest: Encodable {
        var now: Double
        var limit: Int
        var projects: [Project]
        var hints: [String]
        var repositories: [Repository]
    }

    private nonisolated struct CompleteRequest: Encodable {
        var paths: [String]
        var raw: String
        var expanded: String
        var limit: Int
    }

    private nonisolated struct Projects: Decodable {
        var projects: [Project]
    }

    private nonisolated struct Probes: Decodable {
        var probe: [Bool]
    }

    private nonisolated struct Paths: Decodable {
        var paths: [String]
    }

    /// The sessions grouped by folder, then each repository no session names, undated
    /// (`lastActive` nil: the caller reads the folder's date). None when Rust does not answer.
    static func group(_ sessions: [Session], repositories: [String]) -> [Project] {
        WindowRules().call("onboarding_first_run_projects",
                           GroupRequest(sessions: sessions, repositories: repositories),
                           as: Projects.self)?.projects ?? []
    }

    /// Per path, whether its spelling lets it be a project (the caller then probes it);
    /// every path dropped when Rust does not answer.
    static func probes(_ paths: [String], home: String, agentHomes: [String]) -> [Bool] {
        let request = FoldersRequest(home: home, agentHomes: agentHomes, paths: paths)
        guard let probe = WindowRules().call("onboarding_first_run_folders", request, as: Probes.self)?.probe,
              probe.count == paths.count else { return paths.map { _ in false } }
        return probe
    }

    /// `projects` best first; as given when Rust does not answer.
    static func rank(_ projects: [Project], now: Date) -> [Project] {
        WindowRules().call("onboarding_first_run_rank",
                           RankRequest(now: now.timeIntervalSinceReferenceDate, projects: projects),
                           as: Projects.self)?.projects ?? projects
    }

    /// The recent list, at most `limit`; the scan's own projects, capped, when Rust does not answer.
    static func recent(_ projects: [Project], hints: [String], repositories: [Repository], now: Date,
                       limit: Int) -> [Project] {
        let request = RecentRequest(now: now.timeIntervalSinceReferenceDate, limit: limit, projects: projects,
                                    hints: hints, repositories: repositories)
        return WindowRules().call("onboarding_first_run_recent", request, as: Projects.self)?.projects
            ?? Array(projects.prefix(max(1, limit)))
    }

    /// The paths a query completes to; none when Rust does not answer.
    static func complete(_ paths: [String], raw: String, expanded: String, limit: Int) -> [String] {
        WindowRules().call("onboarding_first_run_complete",
                           CompleteRequest(paths: paths, raw: raw, expanded: expanded, limit: limit),
                           as: Paths.self)?.paths ?? []
    }
}

nonisolated extension ProjectRules.Project {
    init(_ project: AgentProject) {
        path = project.folder.path
        sessions = project.sessions
        lastActive = project.lastActive.timeIntervalSinceReferenceDate
        apps = project.apps.map(\.rawValue)
    }

    /// The app's project; an undated one reads its folder's date through `modified`.
    func agentProject(modified: (String) -> Date) -> AgentProject {
        AgentProject(folder: URL(fileURLWithPath: path, isDirectory: true), sessions: sessions,
                     lastActive: lastActive.map(Date.init(timeIntervalSinceReferenceDate:)) ?? modified(path),
                     apps: apps.compactMap(AgentApp.init(rawValue:)))
    }
}
