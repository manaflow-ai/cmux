import Foundation

extension SessionIndexStore {
    nonisolated static func filterVisibleAgents(
        _ entries: [SessionEntry],
        defaults: UserDefaults = .standard
    ) -> [SessionEntry] {
        entries.filter { VaultAgentVisibilitySettings.isAgentEnabled($0.agent, defaults: defaults) }
    }

    nonisolated static func searchEnabledAgents(
        needle: String,
        cwdFilter: String?,
        limit: Int,
        errorBag: ErrorBag
    ) async -> [SessionEntry] {
        let enabledAgents = VaultAgentVisibilitySettings.enabledAgents()
        guard !enabledAgents.isEmpty else { return [] }

        return await withTaskGroup(of: [SessionEntry].self) { group in
            for agent in enabledAgents {
                group.addTask {
                    await timedAgent(
                        needle: needle,
                        agent: agent,
                        cwdFilter: cwdFilter,
                        offset: 0,
                        limit: limit,
                        errorBag: errorBag
                    )
                }
            }

            var merged: [SessionEntry] = []
            for await entries in group {
                merged.append(contentsOf: entries)
            }
            return merged
        }
    }
}
