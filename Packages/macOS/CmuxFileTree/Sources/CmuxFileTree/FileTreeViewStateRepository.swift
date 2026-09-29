public import Foundation

/// Persists ``FileTreeViewState`` per tree scope in `UserDefaults`.
///
/// A scope names one workspace's view of one root (for example
/// `"<workspace-uuid>|local:/Users/me/project"`). The repository keeps the
/// most recently used ``capacity`` scopes and caps each state's path lists so
/// the defaults blob stays small.
public actor FileTreeViewStateRepository {
    private struct Stored: Codable {
        var order: [String] = []
        var states: [String: FileTreeViewState] = [:]
    }

    private let defaults: UserDefaults
    private let key: String
    private let capacity: Int
    private let maxPathsPerState: Int
    private var stored: Stored?

    /// Creates a repository.
    /// - Parameters:
    ///   - defaults: The store; tests pass a suite-scoped instance.
    ///   - key: The defaults key holding every state.
    ///   - capacity: How many scopes to remember, least recently used dropped first.
    ///   - maxPathsPerState: The cap on expanded and selected paths per scope.
    public init(
        defaults: UserDefaults,
        key: String = "fileExplorer.viewStates.v1",
        capacity: Int = 64,
        maxPathsPerState: Int = 2_000
    ) {
        self.defaults = defaults
        self.key = key
        self.capacity = capacity
        self.maxPathsPerState = maxPathsPerState
    }

    /// The saved state for `scope`, if any.
    public func state(for scope: String) -> FileTreeViewState? {
        load().states[scope]
    }

    /// Saves or clears the state for `scope` and marks it most recently used.
    /// - Parameters:
    ///   - state: The state, or `nil` to forget the scope.
    ///   - scope: The scope key.
    public func save(_ state: FileTreeViewState?, for scope: String) {
        var current = load()
        current.order.removeAll { $0 == scope }
        if var state {
            state.expandedPaths = Array(state.expandedPaths.prefix(maxPathsPerState))
            state.selectedPaths = Array(state.selectedPaths.prefix(maxPathsPerState))
            guard current.states[scope] != state || current.order.last != scope else {
                stored = current
                return
            }
            current.states[scope] = state
            current.order.append(scope)
            while current.order.count > capacity {
                let evicted = current.order.removeFirst()
                current.states[evicted] = nil
            }
        } else {
            current.states[scope] = nil
        }
        stored = current
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: key)
        }
    }

    private func load() -> Stored {
        if let stored { return stored }
        let decoded = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        stored = decoded
        return decoded
    }
}
