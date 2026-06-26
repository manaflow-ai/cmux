import CmuxWorkspaces
import Foundation
import Observation
import Bonsplit
import OSLog

private let closedItemHistoryLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "ClosedItemHistory"
)

struct ClosedPanelSplitPlacement: Codable {
    let orientation: SplitOrientation
    let insertFirst: Bool
    let anchorPanelId: UUID?
}

struct ClosedPanelHistoryEntry: Codable {
    let workspaceId: UUID
    let paneId: UUID
    let paneAnchorPanelId: UUID?
    let restoreInOriginalPane: Bool
    let tabIndex: Int
    let snapshot: SessionPanelSnapshot
    let fallbackSplitPlacement: ClosedPanelSplitPlacement?

    init(
        workspaceId: UUID,
        paneId: UUID,
        paneAnchorPanelId: UUID? = nil,
        restoreInOriginalPane: Bool = true,
        tabIndex: Int,
        snapshot: SessionPanelSnapshot,
        fallbackSplitPlacement: ClosedPanelSplitPlacement? = nil
    ) {
        self.workspaceId = workspaceId
        self.paneId = paneId
        self.paneAnchorPanelId = paneAnchorPanelId
        self.restoreInOriginalPane = restoreInOriginalPane
        self.tabIndex = tabIndex
        self.snapshot = snapshot
        self.fallbackSplitPlacement = fallbackSplitPlacement
    }
}

struct ClosedWorkspaceHistoryEntry: Codable {
    let workspaceId: UUID
    let windowId: UUID?
    let workspaceIndex: Int
    let snapshot: SessionWorkspaceSnapshot
}

struct ClosedWindowHistoryEntry: Codable {
    let windowId: UUID?
    let snapshot: SessionWindowSnapshot

    let workspaceIds: [UUID]

    init(windowId: UUID? = nil, snapshot: SessionWindowSnapshot, workspaceIds: [UUID] = []) {
        self.windowId = windowId
        self.snapshot = snapshot
        self.workspaceIds = workspaceIds
    }
}

enum ClosedItemHistoryEntry: Codable {
    case panel(ClosedPanelHistoryEntry)
    case workspace(ClosedWorkspaceHistoryEntry)
    case window(ClosedWindowHistoryEntry)
}

struct ClosedItemHistoryRecord: Identifiable, Codable {
    let id: UUID
    let closedAt: Date
    var entry: ClosedItemHistoryEntry

    init(id: UUID = UUID(), closedAt: Date = Date(), entry: ClosedItemHistoryEntry) {
        self.id = id
        self.closedAt = closedAt
        self.entry = entry
    }
}

struct ClosedItemHistoryMenuItem: Identifiable {
    let id: UUID
    let title: String
    let detail: String
    let closedAt: Date

    var menuSubtitle: String {
        let closed = String(
            format: String(localized: "historyPane.closedAtFormat", defaultValue: "Closed %@"),
            closedAt.formatted(date: .omitted, time: .shortened)
        )
        return String(
            format: String(localized: "menu.history.menuItemSubtitleFormat", defaultValue: "%1$@, %2$@"),
            detail,
            closed
        )
    }

    var menuTitle: String {
        HistoryMenuLineFormatter.titleWithSubtitle(
            title: title,
            subtitle: menuSubtitle
        )
    }
}

struct ClosedItemHistoryMenuSnapshot {
    let items: [ClosedItemHistoryMenuItem]
    let totalItemCount: Int
    let isLimited: Bool
}

enum ClosedWindowRestoreValidation {
    static func hasUsableRestoredContent(
        snapshot: SessionWindowSnapshot,
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]],
        hasLivePanels: Bool
    ) -> Bool {
        guard hasLivePanels else { return false }
        guard snapshot.hasRestorablePanels else { return true }
        return restoredPanelIdsByWorkspaceIndex.contains { !$0.isEmpty }
    }
}

@MainActor
@Observable
final class ClosedItemHistoryStore {
    /// Records that the composition root (``AppDelegate``) has claimed ownership
    /// of the single recently-closed-history store, so the tail call sites
    /// reaching ``shared`` and the root's own ``AppDelegate/closedItemHistory``
    /// reference resolve to the same object. `nonisolated(unsafe)`: written
    /// exactly once at startup before any concurrent reader exists. Retires with
    /// ``shared`` once every call site is injected.
    nonisolated(unsafe) private static var compositionRootInstance: ClosedItemHistoryStore?

    /// The single instance, lazily constructed on first access. A `static let`
    /// of a `@MainActor` type is nonisolated-readable and its initializer runs
    /// the `@MainActor` `init`, the same contract the legacy eager
    /// `static let shared` had. In a normal launch the composition root resolves
    /// and installs this first (via ``installCompositionRootInstance(_:)``) and
    /// holds it as ``AppDelegate/closedItemHistory``.
    private static let instance = ClosedItemHistoryStore(
        capacity: nil,
        fileURL: defaultHistoryFileURL()
    )

    /// Transitional accessor for the de-singletonization (CONVENTIONS §5
    /// `static let shared` → construct-and-inject). The type no longer
    /// self-vivifies an eager `static let shared`; ownership lives at the
    /// composition root (``AppDelegate/closedItemHistory``), which constructs and
    /// holds the instance and uses it directly at the AppDelegate call sites. The
    /// tail of call sites (`Workspace`, `TabManager`, the `cmuxApp` history menu)
    /// still reach the same single object here while they are migrated to the
    /// injected reference; dropping ``shared`` is the end state.
    static var shared: ClosedItemHistoryStore {
        compositionRootInstance ?? instance
    }

    /// Called once by ``AppDelegate`` at startup to record composition-root
    /// ownership of the single instance. Idempotent (keeps the first installed
    /// instance).
    static func installCompositionRootInstance(_ instance: ClosedItemHistoryStore) {
        guard compositionRootInstance == nil else { return }
        compositionRootInstance = instance
    }

    private(set) var revision: UInt64 = 0
    private var records: [ClosedItemHistoryRecord] = []
    private let capacity: Int?
    private let fileURL: URL?
    private let persistsRecordsSynchronously: Bool
    private let persistenceActor: ClosedItemHistoryPersistenceActor
    private var didFinishPersistedRecordsLoad: Bool
    private var needsPersistenceAfterPersistedRecordsLoad = false
    private var shouldDiscardPersistedRecordsOnLoad = false
    private var pendingPersistedRecordMutations: [ClosedItemHistoryRecordMutation] = []

    init(
        capacity: Int? = nil,
        fileURL: URL? = nil,
        loadPersisted: Bool = true,
        loadsPersistedRecordsSynchronously: Bool = false,
        persistsRecordsSynchronously: Bool = false,
        persistenceActor: ClosedItemHistoryPersistenceActor = ClosedItemHistoryPersistenceActor()
    ) {
        self.capacity = capacity.map { max(1, $0) }
        self.fileURL = fileURL
        self.persistsRecordsSynchronously = persistsRecordsSynchronously
        self.persistenceActor = persistenceActor
        self.didFinishPersistedRecordsLoad = !loadPersisted || fileURL == nil
        if loadPersisted, let fileURL {
            if loadsPersistedRecordsSynchronously {
                records = Self.loadRecords(fileURL: fileURL)
                trimToCapacityIfNeeded()
                didFinishPersistedRecordsLoad = true
            } else {
                loadPersistedRecordsAsync(from: fileURL)
            }
        }
    }

    var canReopen: Bool {
        !records.isEmpty
    }

    func push(_ entry: ClosedItemHistoryEntry) {
        push(ClosedItemHistoryRecord(entry: entry))
    }

    func push(_ record: ClosedItemHistoryRecord) {
        records.append(record)
        trimToCapacityIfNeeded()
        revision &+= 1
        persistRecords()
    }

    @discardableResult
    func restoreFirstRestorable(using restore: (ClosedItemHistoryEntry) -> Bool) -> Bool {
        restoreFirstRestorable(newerThan: nil, using: restore)
    }

    @discardableResult
    func restoreFirstRestorable(
        newerThan cutoff: Date?,
        excluding excludedRecordIds: Set<UUID> = [],
        onFailure: ((UUID) -> Void)? = nil,
        using restore: (ClosedItemHistoryEntry) -> Bool
    ) -> Bool {
        let candidates = records.enumerated()
            .filter { _, record in
                guard !excludedRecordIds.contains(record.id) else { return false }
                guard let cutoff else { return true }
                return record.closedAt >= cutoff
            }
            .sorted { lhs, rhs in
                if lhs.element.closedAt != rhs.element.closedAt {
                    return lhs.element.closedAt > rhs.element.closedAt
                }
                return lhs.offset > rhs.offset
            }
            .map { _, record in (id: record.id, entry: record.entry) }
        for candidate in candidates {
            guard restore(candidate.entry) else {
                onFailure?(candidate.id)
                continue
            }
            if let index = records.firstIndex(where: { $0.id == candidate.id }) {
                records.remove(at: index)
                revision &+= 1
                persistRecords()
            }
            return true
        }
        return false
    }

    func removeRecord(id: UUID) -> (record: ClosedItemHistoryRecord, index: Int)? {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let record = records.remove(at: index)
        revision &+= 1
        persistRecords()
        return (record, index)
    }

    func insert(_ record: ClosedItemHistoryRecord, at index: Int) {
        records.insert(record, at: min(max(0, index), records.count))
        if let capacity, records.count > capacity {
            let protectedRecordId = record.id
            let overflow = records.count - capacity
            for _ in 0..<overflow {
                guard let removalIndex = records.firstIndex(where: { $0.id != protectedRecordId }) else {
                    records.removeFirst()
                    continue
                }
                records.remove(at: removalIndex)
            }
        }
        revision &+= 1
        persistRecords()
    }

    func menuSnapshot(maxItemCount: Int? = nil) -> ClosedItemHistoryMenuSnapshot {
        // Build items only for the records the menu will show — this runs in
        // the App commands body on every menu rebuild, and `records` is
        // unbounded persisted history.
        if let maxItemCount, maxItemCount >= 0, records.count > maxItemCount {
            return ClosedItemHistoryMenuSnapshot(
                items: records.suffix(maxItemCount).reversed().map(Self.menuItem(for:)),
                totalItemCount: records.count,
                isLimited: true
            )
        }

        return ClosedItemHistoryMenuSnapshot(
            items: records.reversed().map(Self.menuItem(for:)),
            totalItemCount: records.count,
            isLimited: false
        )
    }

    func remapPanelWorkspaceIds(
        from oldWorkspaceId: UUID,
        to newWorkspaceId: UUID,
        panelIdMap: [UUID: UUID] = [:]
    ) {
        guard oldWorkspaceId != newWorkspaceId else { return }
        let mutation = ClosedItemHistoryRecordMutation.remapPanelWorkspaceIds(
            oldWorkspaceId: oldWorkspaceId,
            newWorkspaceId: newWorkspaceId,
            panelIdMap: panelIdMap
        )
        queuePersistedRecordMutationIfLoading(mutation)
        let result = mutation.apply(to: records)
        if result.didUpdate {
            records = result.records
            revision &+= 1
            persistRecords()
        }
    }

    func remapPanelAnchorIds(from oldPanelId: UUID, to newPanelId: UUID) {
        guard oldPanelId != newPanelId else { return }
        let mutation = ClosedItemHistoryRecordMutation.remapPanelAnchorIds(
            oldPanelId: oldPanelId,
            newPanelId: newPanelId
        )
        queuePersistedRecordMutationIfLoading(mutation)
        let result = mutation.apply(to: records)
        if result.didUpdate {
            records = result.records
            revision &+= 1
            persistRecords()
        }
    }

    func remapWorkspaceWindowIds(from oldWindowId: UUID, to newWindowId: UUID) {
        guard oldWindowId != newWindowId else { return }
        let mutation = ClosedItemHistoryRecordMutation.remapWorkspaceWindowIds(
            oldWindowId: oldWindowId,
            newWindowId: newWindowId
        )
        queuePersistedRecordMutationIfLoading(mutation)
        let result = mutation.apply(to: records)
        if result.didUpdate {
            records = result.records
            revision &+= 1
            persistRecords()
        }
    }

    func removePanelRecords(forWorkspaceIds workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        let mutation = ClosedItemHistoryRecordMutation.removePanelRecords(workspaceIds: workspaceIds)
        queuePersistedRecordMutationIfLoading(mutation)
        let result = mutation.apply(to: records)
        if result.didUpdate {
            records = result.records
            revision &+= 1
            persistRecords()
        }
    }

    func removeAll() {
        guard !records.isEmpty || !didFinishPersistedRecordsLoad else { return }
        if !didFinishPersistedRecordsLoad {
            shouldDiscardPersistedRecordsOnLoad = true
        }
        records.removeAll(keepingCapacity: false)
        revision &+= 1
        persistRecords()
    }

    private func trimToCapacityIfNeeded() {
        guard let capacity, records.count > capacity else { return }
        records.removeFirst(records.count - capacity)
    }

    private func persistRecords() {
        guard let fileURL else { return }
        guard didFinishPersistedRecordsLoad else {
            needsPersistenceAfterPersistedRecordsLoad = true
            return
        }
        let recordsSnapshot = records
        let revisionSnapshot = revision
        if persistsRecordsSynchronously {
            Self.saveRecords(recordsSnapshot, fileURL: fileURL)
        } else {
            Task {
                await persistenceActor.save(
                    recordsSnapshot,
                    fileURL: fileURL,
                    revision: revisionSnapshot
                )
            }
        }
    }

    func flushPendingSaves() {
        guard let fileURL else { return }
        if !didFinishPersistedRecordsLoad {
            finishPersistedRecordsLoad(Self.loadRecords(fileURL: fileURL))
        }
        needsPersistenceAfterPersistedRecordsLoad = false
        let recordsSnapshot = records
        let revisionSnapshot = revision
        if persistsRecordsSynchronously {
            Self.saveRecords(recordsSnapshot, fileURL: fileURL)
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        let persistenceActor = persistenceActor
        Task.detached(priority: .userInitiated) {
            await persistenceActor.save(
                recordsSnapshot,
                fileURL: fileURL,
                revision: revisionSnapshot
            )
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func loadPersistedRecordsAsync(from fileURL: URL) {
        let persistenceActor = persistenceActor
        Task { @MainActor [weak self] in
            let loadedRecords = await persistenceActor.load(fileURL: fileURL)
            guard let self, !didFinishPersistedRecordsLoad else { return }
            finishPersistedRecordsLoad(loadedRecords)
            if needsPersistenceAfterPersistedRecordsLoad {
                needsPersistenceAfterPersistedRecordsLoad = false
                persistRecords()
            }
        }
    }

    private func finishPersistedRecordsLoad(_ loadedRecords: [ClosedItemHistoryRecord]) {
        guard !didFinishPersistedRecordsLoad else { return }
        if !shouldDiscardPersistedRecordsOnLoad {
            var loadedRecords = loadedRecords
            let didMutateLoadedRecords = applyPendingPersistedRecordMutations(to: &loadedRecords)
            mergeLoadedPersistedRecords(loadedRecords)
            if didMutateLoadedRecords {
                needsPersistenceAfterPersistedRecordsLoad = true
            }
        } else {
            pendingPersistedRecordMutations.removeAll(keepingCapacity: false)
        }
        didFinishPersistedRecordsLoad = true
        shouldDiscardPersistedRecordsOnLoad = false
    }

    private func queuePersistedRecordMutationIfLoading(_ mutation: ClosedItemHistoryRecordMutation) {
        guard !didFinishPersistedRecordsLoad else { return }
        pendingPersistedRecordMutations.append(mutation)
    }

    @discardableResult
    private func applyPendingPersistedRecordMutations(to loadedRecords: inout [ClosedItemHistoryRecord]) -> Bool {
        guard !pendingPersistedRecordMutations.isEmpty else { return false }
        var didUpdate = false
        for mutation in pendingPersistedRecordMutations {
            let result = mutation.apply(to: loadedRecords)
            loadedRecords = result.records
            didUpdate = didUpdate || result.didUpdate
        }
        pendingPersistedRecordMutations.removeAll(keepingCapacity: false)
        return didUpdate
    }

    private func mergeLoadedPersistedRecords(_ loadedRecords: [ClosedItemHistoryRecord]) {
        guard !loadedRecords.isEmpty else { return }
        if records.isEmpty {
            records = loadedRecords
        } else {
            var seenRecordIds = Set(records.map(\.id))
            let missingLoadedRecords = loadedRecords.filter { seenRecordIds.insert($0.id).inserted }
            guard !missingLoadedRecords.isEmpty else { return }
            records = missingLoadedRecords + records
        }
        trimToCapacityIfNeeded()
        revision &+= 1
    }

    nonisolated static func loadRecords(fileURL: URL) -> [ClosedItemHistoryRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        if let snapshot = try? decoder.decode(ClosedItemHistoryPersistenceSnapshot.self, from: data),
           snapshot.version == ClosedItemHistoryPersistenceSnapshot.currentVersion {
            return snapshot.records
        }
        return (try? decoder.decode([ClosedItemHistoryRecord].self, from: data)) ?? []
    }

    nonisolated static func saveRecords(_ records: [ClosedItemHistoryRecord], fileURL: URL) {
        guard !records.isEmpty else {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    closedItemHistoryLogger.debug(
                        "closedItemHistory.remove.failed file=\(fileURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let snapshot = ClosedItemHistoryPersistenceSnapshot(records: records)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            if let existingData = try? Data(contentsOf: fileURL), existingData == data {
                return
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            closedItemHistoryLogger.debug(
                "closedItemHistory.save.failed file=\(fileURL.path, privacy: .public) records=\(records.count) error=\(error.localizedDescription, privacy: .public)"
            )
            return
        }
    }

    nonisolated private static func defaultHistoryFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy().isRunningUnderAutomatedTests
    ) -> URL? {
        guard !isRunningUnderAutomatedTests else { return nil }
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.cmuxterm.app"
        let safeBundleId = bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return resolvedAppSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("closed-item-history-\(safeBundleId).json", isDirectory: false)
    }

    private static func menuItem(for record: ClosedItemHistoryRecord) -> ClosedItemHistoryMenuItem {
        switch record.entry {
        case .panel(let entry):
            return ClosedItemHistoryMenuItem(
                id: record.id,
                title: title(for: entry.snapshot),
                detail: String(localized: "menu.history.recentlyClosed.kind.tab", defaultValue: "Tab"),
                closedAt: record.closedAt
            )
        case .workspace(let entry):
            return ClosedItemHistoryMenuItem(
                id: record.id,
                title: title(for: entry.snapshot),
                detail: String(localized: "menu.history.recentlyClosed.kind.workspace", defaultValue: "Workspace"),
                closedAt: record.closedAt
            )
        case .window(let entry):
            return ClosedItemHistoryMenuItem(
                id: record.id,
                title: String(localized: "menu.history.recentlyClosed.kind.window", defaultValue: "Window"),
                detail: windowWorkspaceCountLabel(entry.snapshot.tabManager.workspaces.count),
                closedAt: record.closedAt
            )
        }
    }

    private static func title(for snapshot: SessionPanelSnapshot) -> String {
        let candidates = [
            snapshot.customTitle,
            snapshot.title,
            // String-only path math — NOT URL(fileURLWithPath:), which lstat()s
            // the path to infer directory-ness. These snapshots can hold REMOTE
            // working directories (closed remote-tmux tabs); stat'ing one on the
            // main thread blocks on the autofs automounter (e.g. /home/…) for
            // hundreds of ms per record, and this runs inside the App commands
            // body on every menu rebuild.
            snapshot.directory.map { ($0 as NSString).lastPathComponent }
        ]
        if let title = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return title
        }

        switch snapshot.type {
        case .terminal:
            return String(localized: "menu.history.recentlyClosed.panel.terminal", defaultValue: "Terminal")
        case .browser:
            return String(localized: "menu.history.recentlyClosed.panel.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "menu.history.recentlyClosed.panel.markdown", defaultValue: "Markdown")
        case .filePreview:
            return String(localized: "menu.history.recentlyClosed.panel.filePreview", defaultValue: "File Preview")
        case .rightSidebarTool:
            if let mode = snapshot.rightSidebarTool?.mode {
                return mode.label
            }
            return String(localized: "menu.history.recentlyClosed.panel.tool", defaultValue: "Tool")
        case .agentSession:
            return String(localized: "menu.history.recentlyClosed.panel.agentSession", defaultValue: "Agent")
        case .project:
            return String(localized: "menu.history.recentlyClosed.panel.project", defaultValue: "Project")
        case .extensionBrowser:
            return String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
        }
    }

    private static func title(for snapshot: SessionWorkspaceSnapshot) -> String {
        let candidates = [
            snapshot.customTitle,
            Optional(snapshot.processTitle),
            directoryTitleCandidate(snapshot.currentDirectory)
        ]
        if let title = candidates.compactMap({ normalizedTitleCandidate($0) })
            .first(where: { !$0.isEmpty }) {
            return title
        }
        return String(localized: "menu.history.untitledWorkspace", defaultValue: "Untitled Workspace")
    }

    private static func directoryTitleCandidate(_ directory: String) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "." else { return nil }
        // String-only path math — see title(for:): URL(fileURLWithPath:) would
        // lstat() a possibly-remote path on the main thread.
        return (trimmed as NSString).lastPathComponent
    }

    private static func normalizedTitleCandidate(_ candidate: String?) -> String? {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "." else { return nil }
        return trimmed
    }

    private static func windowWorkspaceCountLabel(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "menu.history.recentlyClosed.window.workspaceCount.one", defaultValue: "1 workspace")
        }
        return String.localizedStringWithFormat(
            String(
                localized: "menu.history.recentlyClosed.window.workspaceCount.other",
                defaultValue: "%d workspaces"
            ),
            count
        )
    }
}

private struct ClosedItemHistoryPersistenceSnapshot: Codable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var records: [ClosedItemHistoryRecord]
}
