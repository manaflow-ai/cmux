import CmuxNextActions
import CmuxNextCompat

extension RegistryControlBridge {
    /// The catalog's actions as last built, with the action id each one's
    /// unavailable reason is read for. The bridge keeps one and patches its
    /// reasons in place; the context mask is added when it is published.
    @MainActor
    struct BuiltCatalog {
        /// The published catalog, its context mask aside: patched in place, so a reason change
        /// rebuilds neither the actions nor their lookup tables.
        private var published: ControlCatalog
        /// The registry id of each action, in the same order.
        let ids: [ActionID]

        /// Everything but the reasons, which stay nil until ``apply(reasons:)``.
        init(registry: ActionRegistry) {
            // Localized once per build, not once per action.
            let categoryTitles = Dictionary(uniqueKeysWithValues: ActionCategory.allCases.map { ($0, $0.title) })
            let entries = registry.entries
            ids = entries.map(\.descriptor.id)
            published = ControlCatalog(
                actions: entries.map { RegistryControlBridge.structureInfo(for: $0, in: registry, categoryTitles: categoryTitles) },
                aliases: Dictionary(uniqueKeysWithValues: registry.aliases.map { ($0.key.rawValue, $0.value.rawValue) }),
                targetKinds: ActionTargetKind.allCases.map(\.rawValue),
                debugActionsAvailable: DevTools.isEnabled
            )
        }

        /// Each action's unavailable reason, in the order of ``ids``.
        var reasons: [String?] { published.actions.map(\.unavailableReason) }

        /// Stores `reasons` (one per id) and says whether any differed.
        @discardableResult
        mutating func apply(reasons: [String?]) -> Bool {
            var changed = false
            for (index, reason) in zip(published.actions.indices, reasons) {
                if setReason(reason, at: index) { changed = true }
            }
            return changed
        }

        /// Stores the reason of the action at `index` and says whether it differed.
        mutating func setReason(_ reason: String?, at index: Int) -> Bool {
            var changed = false
            published.actions.modify(checked: index) { action in
                guard action.unavailableReason != reason else { return }
                action.unavailableReason = reason
                changed = true
            }
            return changed
        }

        func catalog(contextMask: UInt32) -> ControlCatalog {
            var catalog = published
            catalog.contextMask = contextMask
            return catalog
        }
    }

    /// The actions whose reason observation fired: noted on the thread that changed the state the
    /// reason reads (an observation fires there, before the change is stored), taken by the refresh
    /// on the main actor. A note armed under an older generation (a full read since) is dropped.
    final class FiredReasons: Sendable {
        private struct State {
            var indices: [Int] = []
            var generation: UInt64 = 0
            var firings = 0
        }

        private let state = Mutex(State())

        /// Notes that the reason observation of the action at `index`, armed under `generation`, fired.
        /// True for the first note since the last take: its caller schedules the refresh.
        func note(_ index: Int, generation: UInt64) -> Bool {
            state.withLock { state in
                state.firings += 1
                guard generation == state.generation else { return false }
                state.indices.append(index)
                return state.indices.count == 1
            }
        }

        /// The actions noted since the last take; from now on only notes of `generation` count.
        func take(generation: UInt64) -> [Int] {
            state.withLock { state in
                state.generation = generation
                let taken = state.indices
                state.indices.removeAll(keepingCapacity: true)
                return taken
            }
        }

        /// Every firing noted, of any generation (tests).
        var firings: Int { state.withLock { $0.firings } }
    }
}
