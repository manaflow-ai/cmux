// Sources/Island/IslandStateStore.swift

import Combine
import Foundation

/// Concrete `IslandStateProvider` that projects an `IslandStateSource` into
/// a sorted, debounced `[IslandSession]` publisher the view observes.
///
/// The store itself does no model reading — all data comes via the source,
/// which is either the production `TabManagerIslandStateSource` (added in
/// Task 6) or a test/debug fake such as `InMemoryIslandStateSource`.
@MainActor
final class IslandStateStore: IslandStateProvider, ObservableObject {

    private let source: IslandStateSource
    private let subject: CurrentValueSubject<[IslandSession], Never>
    private var cancellable: AnyCancellable?

    init(source: IslandStateSource) {
        self.source = source
        let initial = source.makeSnapshot().sorted(by: <)
        self.subject = CurrentValueSubject(initial)

        // Debounce 50ms so back-to-back set-status/notify bursts coalesce
        // into a single emission instead of one per upstream tick.
        self.cancellable = source.changes
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                let snapshot = self.source.makeSnapshot().sorted(by: <)
                self.subject.send(snapshot)
            }
    }

    var sessionsPublisher: AnyPublisher<[IslandSession], Never> {
        subject.eraseToAnyPublisher()
    }

    var currentSessions: [IslandSession] {
        subject.value
    }
}

// MARK: - Production source wrapping TabManager

/// Production `IslandStateSource` that subscribes to every `Workspace`
/// inside a `TabManager` and emits `changes` whenever any relevant state
/// updates. Reads `TerminalNotificationStore.shared` for unread counts.
///
/// Deliberately isolated in one file so the `Sources/Island/` module has
/// exactly one symbol that imports cmux core types.
@MainActor
final class TabManagerIslandStateSource: IslandStateSource {

    private let tabManager: TabManager
    private let subject = PassthroughSubject<Void, Never>()
    private var tabsCancellable: AnyCancellable?
    private var perWorkspaceCancellables: [UUID: Set<AnyCancellable>] = [:]
    private var notificationCancellable: AnyCancellable?

    init(tabManager: TabManager) {
        self.tabManager = tabManager

        // 1. Any change to the tabs array → rebuild per-workspace subscriptions
        //    and fire a change tick. Prime with the current tabs so existing
        //    workspaces get observers even if the tabs array never mutates
        //    again before the first snapshot.
        resubscribe(to: tabManager.tabs)

        tabsCancellable = tabManager.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs in
                self?.resubscribe(to: tabs)
                self?.subject.send(())
            }

        // 2. Notifications (unread counts) tick. The store is ObservableObject,
        //    so objectWillChange fires on every mutation; we only need a tick
        //    to re-snapshot — the store itself is read inside makeSnapshot.
        notificationCancellable = TerminalNotificationStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.subject.send(())
            }
    }

    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    @MainActor
    func makeSnapshot() -> [IslandSession] {
        var out: [IslandSession] = []
        let knownKeys = Set(IslandAgentKind.allCases.map(\.rawValue))

        for workspace in tabManager.tabs {
            // Find the highest-priority status entry whose key is a known
            // agent kind. Ties broken by most recent timestamp (spec §5.2).
            let matching = workspace.statusEntries.filter { knownKeys.contains($0.key) }
            guard !matching.isEmpty else { continue }

            let sorted = matching.values.sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.timestamp > rhs.timestamp
            }
            guard let winner = sorted.first else { continue }
            guard let kind = IslandAgentKind(rawValue: winner.key) else { continue }

            // Session binds to the workspace's currently focused panel, or
            // the first panel in the workspace if nothing is focused. This
            // is good enough for MVP — panel-specific `set-status --tab`
            // resolution is Phase 2.
            guard let panelId = workspace.focusedPanelId
                ?? workspace.panels.keys.first else { continue }

            let workspaceTitle = workspace.customTitle ?? workspace.title
            let panelTitle = workspace.panelCustomTitles[panelId]
                ?? workspace.panelTitles[panelId]
                ?? workspace.panels[panelId]?.displayTitle
                ?? "panel"

            // Unread count — see helper comment. Workspace-scoped for MVP.
            let unread = Self.unreadCount(forWorkspaceId: workspace.id, panelId: panelId)

            out.append(
                IslandSession(
                    id: panelId,
                    workspaceId: workspace.id,
                    panelId: panelId,
                    agentKind: kind,
                    phase: IslandSessionPhase.from(rawValue: winner.value),
                    workspaceTitle: workspaceTitle,
                    panelTitle: panelTitle,
                    lastActivity: winner.timestamp,
                    unreadCount: unread,
                    rawStatusValue: winner.value
                )
            )
        }
        return out
    }

    // MARK: - Private

    /// TerminalNotificationStore exposes workspace-scoped counts
    /// (`unreadCount(forTabId:)`) and a per-panel presence Bool
    /// (`hasUnreadNotification(forTabId:surfaceId:)`), but no per-panel
    /// count. For MVP we report the workspace-scoped count when the panel
    /// is the one holding an unread indicator, otherwise 0.
    ///
    // TODO(Phase 2): replace with a true per-panel count once
    // TerminalNotificationStore exposes `unreadCount(forTabId:surfaceId:)`.
    @MainActor
    private static func unreadCount(forWorkspaceId workspaceId: UUID, panelId: UUID) -> Int {
        let store = TerminalNotificationStore.shared
        guard store.hasUnreadNotification(forTabId: workspaceId, surfaceId: panelId) else {
            return 0
        }
        return store.unreadCount(forTabId: workspaceId)
    }

    private func resubscribe(to tabs: [Workspace]) {
        let presentIds = Set(tabs.map(\.id))

        // Drop observers for removed workspaces.
        let removed = Set(perWorkspaceCancellables.keys).subtracting(presentIds)
        for id in removed { perWorkspaceCancellables.removeValue(forKey: id) }

        // Add observers for new workspaces.
        for tab in tabs where perWorkspaceCancellables[tab.id] == nil {
            var bag = Set<AnyCancellable>()

            tab.$statusEntries
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.subject.send(()) }
                .store(in: &bag)

            tab.$panelTitles
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.subject.send(()) }
                .store(in: &bag)

            tab.$panelCustomTitles
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.subject.send(()) }
                .store(in: &bag)

            tab.$panels
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.subject.send(()) }
                .store(in: &bag)

            tab.$title
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.subject.send(()) }
                .store(in: &bag)

            tab.$customTitle
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.subject.send(()) }
                .store(in: &bag)

            perWorkspaceCancellables[tab.id] = bag
        }
    }
}
