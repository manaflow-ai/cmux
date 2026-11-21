import Foundation

/// Facts from the app's live mirrors, used only before a Chief conversation starts.
public nonisolated struct HomeStarterContext: Sendable, Equatable {
    public var workspaces: [String]
    public var working: [String]
    public var failures: [String]
    public var pullRequests: [String]

    public init(workspaces: [String] = [], working: [String] = [], failures: [String] = [], pullRequests: [String] = []) {
        self.workspaces = workspaces
        self.working = working
        self.failures = failures
        self.pullRequests = pullRequests
    }

    /// Three to five prompts; missing activity gets setup questions, never invented work.
    @MainActor public var prompts: [String] {
        var result: [String] = []
        if let name = failures.first { result.append(HomeStarterStrings.failure(name)) }
        if let name = working.first { result.append(HomeStarterStrings.running(name)) }
        if let name = pullRequests.first { result.append(HomeStarterStrings.review(name)) }
        for name in workspaces where !name.isEmpty {
            let prompt = HomeStarterStrings.workspace(name)
            if !result.contains(prompt) { result.append(prompt) }
            if result.count == 5 { break }
        }
        for prompt in [workspaces.isEmpty ? HomeStarterStrings.setup : nil,
                       working.isEmpty ? HomeStarterStrings.agent : nil,
                       HomeStarterStrings.task].compactMap({ $0 }) where result.count < 3 {
            result.append(prompt)
        }
        return result
    }
}
