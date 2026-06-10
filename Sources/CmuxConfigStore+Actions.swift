import Bonsplit
import CmuxFileWatch
import Combine
import CryptoKit
import Foundation


// MARK: - Action Resolution
extension CmuxConfigStore {
    func actionEntries(
        from actions: [String: CmuxConfigActionDefinition],
        sourcePath: String?
    ) -> [String: ActionEntry] {
        actions.mapValues { ActionEntry(definition: $0, sourcePath: sourcePath) }
    }

    private func mergedActionEntries(
        primary: [String: ActionEntry],
        fallback: [String: ActionEntry]
    ) -> [String: ActionEntry] {
        fallback.merging(primary) { _, primary in primary }
    }

    func resolvedActionRegistry(
        globalActions: [String: ActionEntry],
        localActions: [String: ActionEntry],
        commands: [CmuxCommandDefinition],
        commandSourcePaths: [String: String]
    ) -> [CmuxResolvedConfigAction] {
        var registry = Dictionary(
            uniqueKeysWithValues: CmuxSurfaceTabBarBuiltInAction.allCases.map {
                ($0.configID, CmuxResolvedConfigAction.builtIn($0))
            }
        )

        func apply(_ entries: [String: ActionEntry]) {
            for (id, entry) in entries {
                let registryID = CmuxSurfaceTabBarBuiltInAction(configID: id)?.configID ?? id
                if let existing = registry[registryID] {
                    guard let resolved = existing.applying(entry.definition, sourcePath: entry.sourcePath) else { continue }
                    registry[registryID] = resolved
                } else if let resolved = CmuxResolvedConfigAction.fromDefinition(
                    id: id,
                    definition: entry.definition,
                    sourcePath: entry.sourcePath
                ) {
                    registry[id] = resolved
                } else {
                    NSLog("[CmuxConfig] action '%@' ignored because it does not define a runnable action", id)
                }
            }
        }

        apply(globalActions)
        apply(localActions)

        for command in commands where registry[command.id] == nil {
            let sourcePath = commandSourcePaths[command.id]
            registry[command.id] = CmuxResolvedConfigAction(
                id: command.id,
                title: String(
                    localized: "command.cmuxConfig.customTitle",
                    defaultValue: "Custom: \(sanitizeConfigText(command.name))"
                ),
                subtitle: command.description.map { sanitizeConfigText($0) }
                    ?? String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json"),
                keywords: command.keywords ?? [],
                palette: true,
                shortcut: nil,
                icon: .symbol(command.workspace == nil ? "terminal" : "rectangle.stack.badge.plus"),
                tooltip: command.description,
                action: command.workspace == nil
                    ? .command(command.command ?? "")
                    : .workspaceCommand(command.name),
                confirm: command.confirm,
                terminalCommandTarget: command.workspace == nil ? .currentTerminal : nil,
                actionSourcePath: sourcePath,
                iconSourcePath: nil
            )
        }

        return registry.values.sorted { lhs, rhs in
            lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    func resolvedAction(id: String) -> CmuxResolvedConfigAction? {
        actionLookup[canonicalActionID(id)]
    }

    func paletteCustomActions() -> [CmuxResolvedConfigAction] {
        let builtInIDs = Set(CmuxSurfaceTabBarBuiltInAction.allCases.map(\.configID))
        return loadedActions.filter { action in
            action.palette && !builtInIDs.contains(action.id)
        }
    }

    func shortcutActions() -> [CmuxResolvedConfigAction] {
        let builtInIDs = Set(CmuxSurfaceTabBarBuiltInAction.allCases.map(\.configID))
        return loadedActions.filter { action in
            action.shortcut != nil && (builtInIDs.contains(action.id) || action.actionSourcePath != nil)
        }.sorted { lhs, rhs in
            let lhsPriority = builtInIDs.contains(lhs.id) ? 0 : 1
            let rhsPriority = builtInIDs.contains(rhs.id) ? 0 : 1
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    func canonicalActionID(_ id: String) -> String {
        CmuxSurfaceTabBarBuiltInAction(configID: id)?.configID ?? id
    }

}
