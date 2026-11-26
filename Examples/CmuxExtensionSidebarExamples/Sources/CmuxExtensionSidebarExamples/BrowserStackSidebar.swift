import CmuxSidebarProviderKit
import Foundation

public struct BrowserStackSidebar: CmuxMutableSidebarProvider {
    public static let stateDidLoadNotification = Notification.Name("CmuxBrowserStackSidebarStateDidLoad")

    public let descriptor = CmuxSidebarProviderDescriptor(
        id: "com.example.cmux.sidebar.browser-stack",
        title: localized("example.sidebar.browserStack.title", "Browser Stack"),
        subtitle: localized("example.sidebar.browserStack.subtitle", "User extension"),
        systemImageName: "square.on.square",
        isHostProvided: false
    )
    private let stateCache: BrowserStackSidebarStateCache

    public init(
        store: BrowserStackSidebarStore = BrowserStackSidebarStore(),
        initialState: BrowserStackSidebarState? = nil,
        onAsyncStateLoaded: (@Sendable () -> Void)? = nil
    ) {
        self.stateCache = BrowserStackSidebarStateCache(
            store: store,
            initialState: initialState,
            onAsyncStateLoaded: onAsyncStateLoaded
        )
    }

    public static func postStateDidLoadNotification() {
        NotificationCenter.default.post(name: stateDidLoadNotification, object: nil)
    }

    public func render(snapshot: CmuxSidebarProviderSnapshot) -> CmuxSidebarProviderRenderModel {
        let state = stateCache.state(for: snapshot)
        let workspacesById = Dictionary(
            snapshot.workspaces.map { ($0.id, $0) },
            uniquingKeysWith: { _, replacement in replacement }
        )
        let sections = state.sections.map { sectionState in
            ExampleSidebarSection(
                id: sectionState.id,
                title: localized(
                    "example.sidebar.browserStack.section.\(sectionState.id)",
                    sectionState.title
                ),
                systemImageName: sectionState.systemImageName,
                projectRootPath: nil,
                workspaces: sectionState.workspaceIds.compactMap { workspacesById[$0] }
            )
            .render(
                accessory: nil,
                trailingText: recentActivityText,
                leadingIcon: browserIcon
            )
        }

        return renderModel(
            providerId: descriptor.id,
            snapshot: snapshot,
            sections: sections,
            presentation: .browserStack
        )
    }

    public func handle(
        _ mutation: CmuxSidebarProviderMutation,
        snapshot: CmuxSidebarProviderSnapshot
    ) throws -> CmuxSidebarProviderCommandResult {
        guard case .moveWorkspace(let move) = mutation else {
            return CmuxSidebarProviderCommandResult(ok: false)
        }
        stateCache.moveWorkspace(move, snapshot: snapshot)
        return CmuxSidebarProviderCommandResult(ok: true)
    }

    private func recentActivityText(_ workspace: CmuxSidebarProviderWorkspace) -> CmuxSidebarProviderText? {
        workspace.latestSubmittedAt.map { .relativeDate($0, style: .compact) }
    }

    private func browserIcon(_ workspace: CmuxSidebarProviderWorkspace) -> CmuxSidebarProviderIcon? {
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let titleTokens = Set(title.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if title.contains("google") {
            return CmuxSidebarProviderIcon(
                text: "G",
                foregroundColorHex: "#4285F4",
                backgroundColorHex: "#FFFFFF"
            )
        }
        if title.contains("hacker")
            || title.contains("ycombinator")
            || title.contains("y combinator")
            || titleTokens.contains("yc") {
            return CmuxSidebarProviderIcon(
                text: "Y",
                foregroundColorHex: "#FFFFFF",
                backgroundColorHex: "#FF6600",
                shape: .roundedRectangle
            )
        }
        if title == "x" || title.hasPrefix("x.") || title.contains("twitter") || title.contains("what's happening") {
            return CmuxSidebarProviderIcon(
                text: "X",
                foregroundColorHex: "#FFFFFF",
                backgroundColorHex: "#000000",
                shape: .roundedRectangle
            )
        }
        let isDiaBrowser = title == "dia"
            || titleTokens.contains("dia")
            || title.contains("dia browser")
        if isDiaBrowser {
            return CmuxSidebarProviderIcon(
                systemImageName: "bubble.left.fill",
                foregroundColorHex: "#D8D8D8",
                backgroundColorHex: "#000000"
            )
        }
        return CmuxSidebarProviderIcon(
            systemImageName: "bubble.left.fill",
            foregroundColorHex: "#D0D0D0",
            backgroundColorHex: "#5A5A5A"
        )
    }
}

private final class BrowserStackSidebarStateCache: @unchecked Sendable {
    private struct ScopedState {
        var state: BrowserStackSidebarState?
        var didStartLoad: Bool
        var mutationGeneration: UInt64
    }

    private static let legacyScopeKey = "legacy"

    private let store: BrowserStackSidebarStore
    private let onAsyncStateLoaded: (@Sendable () -> Void)?
    private let lock = NSLock()
    private let persistenceQueue = DispatchQueue(label: "cmux.browser-stack-sidebar.persistence")
    private let initialState: BrowserStackSidebarState?
    private var statesByScope: [String: ScopedState] = [:]

    init(
        store: BrowserStackSidebarStore,
        initialState: BrowserStackSidebarState?,
        onAsyncStateLoaded: (@Sendable () -> Void)?
    ) {
        self.store = store
        self.onAsyncStateLoaded = onAsyncStateLoaded
        self.initialState = initialState
        if initialState != nil {
            statesByScope[Self.legacyScopeKey] = ScopedState(
                state: initialState,
                didStartLoad: true,
                mutationGeneration: 0
            )
        }
    }

    func state(for snapshot: CmuxSidebarProviderSnapshot) -> BrowserStackSidebarState {
        let scopeKey = Self.scopeKey(for: snapshot)
        startLoadIfNeeded(scopeKey: scopeKey, snapshot: snapshot)
        lock.lock()
        var scopedState = scopedState(for: scopeKey)
        let base = scopedState.state ?? BrowserStackSidebarState.initial(snapshot: snapshot)
        let reconciled = base.reconciled(with: snapshot)
        scopedState.state = reconciled
        statesByScope[scopeKey] = scopedState
        lock.unlock()
        return reconciled
    }

    func moveWorkspace(
        _ move: CmuxSidebarProviderWorkspaceMove,
        snapshot: CmuxSidebarProviderSnapshot
    ) {
        let scopeKey = Self.scopeKey(for: snapshot)
        let updated: BrowserStackSidebarState
        lock.lock()
        var scopedState = scopedState(for: scopeKey)
        scopedState.mutationGeneration &+= 1
        var next = (scopedState.state ?? BrowserStackSidebarState.initial(snapshot: snapshot)).reconciled(with: snapshot)
        next.moveWorkspace(move)
        updated = next.reconciled(with: snapshot)
        scopedState.state = updated
        scopedState.didStartLoad = true
        statesByScope[scopeKey] = scopedState
        lock.unlock()
        persist(updated, scopeKey: scopeKey)
    }

    private func startLoadIfNeeded(scopeKey: String, snapshot: CmuxSidebarProviderSnapshot) {
        let generation: UInt64
        lock.lock()
        var scopedState = scopedState(for: scopeKey)
        if scopedState.didStartLoad {
            lock.unlock()
            return
        }
        scopedState.didStartLoad = true
        generation = scopedState.mutationGeneration
        statesByScope[scopeKey] = scopedState
        lock.unlock()

        Task.detached(priority: .utility) { [store, scopeKey, snapshot] in
            guard let loaded = try? store.load(scopeKey: scopeKey, snapshot: snapshot) else { return }
            self.applyLoadedState(loaded, scopeKey: scopeKey, generation: generation)
        }
    }

    private func applyLoadedState(_ loaded: BrowserStackSidebarState, scopeKey: String, generation: UInt64) {
        let shouldNotify: Bool
        lock.lock()
        var scopedState = scopedState(for: scopeKey)
        if scopedState.mutationGeneration == generation {
            scopedState.state = loaded
            statesByScope[scopeKey] = scopedState
            shouldNotify = true
        } else {
            shouldNotify = false
        }
        lock.unlock()
        if shouldNotify {
            onAsyncStateLoaded?()
        }
    }

    private func persist(_ state: BrowserStackSidebarState, scopeKey: String) {
        persistenceQueue.async { [store, scopeKey] in
            try? store.save(state, scopeKey: scopeKey)
        }
    }

    private func scopedState(for scopeKey: String) -> ScopedState {
        let scopedInitialState = scopeKey == Self.legacyScopeKey ? initialState : nil
        return statesByScope[scopeKey] ?? ScopedState(
            state: scopedInitialState,
            didStartLoad: scopedInitialState != nil,
            mutationGeneration: 0
        )
    }

    private static func scopeKey(for snapshot: CmuxSidebarProviderSnapshot) -> String {
        if let windowId = snapshot.windowId {
            return "window-\(windowId.uuidString.lowercased())"
        }
        return legacyScopeKey
    }
}

public struct BrowserStackSidebarStore: Sendable {
    public var stateURL: URL

    public init(stateURL: URL = BrowserStackSidebarStore.defaultStateURL()) {
        self.stateURL = stateURL
    }

    public static func defaultStateURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent("browser-stack-sidebar", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    public func load() throws -> BrowserStackSidebarState {
        try load(from: stateURL)
    }

    public func load(scopeKey: String) throws -> BrowserStackSidebarState {
        let url = scopedStateURL(scopeKey: scopeKey)
        if url != stateURL, FileManager.default.fileExists(atPath: url.path) {
            return try load(from: url)
        }
        return try load()
    }

    public func load(scopeKey: String, snapshot: CmuxSidebarProviderSnapshot) throws -> BrowserStackSidebarState {
        let url = scopedStateURL(scopeKey: scopeKey)
        if url != stateURL, FileManager.default.fileExists(atPath: url.path) {
            return try load(from: url)
        }
        if let fallback = try loadBestScopedFallback(matching: snapshot, excluding: url) {
            return fallback
        }
        return try load()
    }

    public func save(_ state: BrowserStackSidebarState) throws {
        try save(state, to: stateURL)
    }

    public func save(_ state: BrowserStackSidebarState, scopeKey: String) throws {
        try save(state, to: scopedStateURL(scopeKey: scopeKey))
    }

    private func load(from url: URL) throws -> BrowserStackSidebarState {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BrowserStackSidebarState.self, from: data)
    }

    private func save(_ state: BrowserStackSidebarState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic])
    }

    private func scopedStateURL(scopeKey: String) -> URL {
        guard scopeKey != "legacy" else { return stateURL }
        let directory = stateURL.deletingLastPathComponent()
        let baseName = stateURL.deletingPathExtension().lastPathComponent
        let pathExtension = stateURL.pathExtension
        let scopedName = "\(baseName)-\(scopeKey)"
        if pathExtension.isEmpty {
            return directory.appendingPathComponent(scopedName)
        }
        return directory.appendingPathComponent(scopedName).appendingPathExtension(pathExtension)
    }

    private func loadBestScopedFallback(
        matching snapshot: CmuxSidebarProviderSnapshot,
        excluding excludedURL: URL
    ) throws -> BrowserStackSidebarState? {
        let liveIds = Set(snapshot.workspaceIds)
        guard !liveIds.isEmpty else { return nil }

        let directory = stateURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return nil }

        let baseName = stateURL.deletingPathExtension().lastPathComponent
        let pathExtension = stateURL.pathExtension
        let prefix = "\(baseName)-"
        let candidates = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var best: (state: BrowserStackSidebarState, overlap: Int, extra: Int, modified: Date)?
        for candidate in candidates where candidate != stateURL && candidate != excludedURL {
            guard candidate.lastPathComponent.hasPrefix(prefix),
                  pathExtension.isEmpty || candidate.pathExtension == pathExtension,
                  let state = try? load(from: candidate) else {
                continue
            }

            let stateIds = Set(state.sections.flatMap(\.workspaceIds))
            let overlap = stateIds.intersection(liveIds).count
            guard overlap > 0 else { continue }
            let extra = stateIds.subtracting(liveIds).count
            let modified = (try? candidate.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            if let current = best,
               overlap < current.overlap
                || (overlap == current.overlap && extra > current.extra)
                || (overlap == current.overlap && extra == current.extra && modified <= current.modified) {
                continue
            }
            best = (state, overlap, extra, modified)
        }
        return best?.state
    }

    public func reconciledState(for snapshot: CmuxSidebarProviderSnapshot) throws -> BrowserStackSidebarState {
        let loaded = (try? load()) ?? BrowserStackSidebarState.initial(snapshot: snapshot)
        return loaded.reconciled(with: snapshot)
    }

    public func moveWorkspace(
        _ move: CmuxSidebarProviderWorkspaceMove,
        snapshot: CmuxSidebarProviderSnapshot
    ) throws -> BrowserStackSidebarState {
        var state = try reconciledState(for: snapshot)
        state.moveWorkspace(move)
        let reconciled = state.reconciled(with: snapshot)
        try save(reconciled)
        return reconciled
    }
}

public struct BrowserStackSidebarState: Codable, Equatable, Sendable {
    public var sections: [BrowserStackSidebarSectionState]

    public init(sections: [BrowserStackSidebarSectionState]) {
        self.sections = sections
    }

    public static func initial(snapshot: CmuxSidebarProviderSnapshot) -> BrowserStackSidebarState {
        let ids = snapshot.workspaceIds
        return BrowserStackSidebarState(sections: [
            BrowserStackSidebarSectionState(
                id: BrowserStackSidebarSectionState.tilesSectionId,
                title: "Pinned",
                kind: .tiles,
                workspaceIds: Array(ids.prefix(3))
            ),
            BrowserStackSidebarSectionState(
                id: BrowserStackSidebarSectionState.looseSectionId,
                title: "Open",
                kind: .loose,
                workspaceIds: Array(ids.dropFirst(3).prefix(5))
            ),
            BrowserStackSidebarSectionState(
                id: "group:reading-list",
                title: "Reading List",
                kind: .group,
                workspaceIds: Array(ids.dropFirst(8))
            ),
        ])
    }

    public func reconciled(with snapshot: CmuxSidebarProviderSnapshot) -> BrowserStackSidebarState {
        let liveIds = Set(snapshot.workspaceIds)
        var seen = Set<UUID>()
        var nextSections = sections.map { section -> BrowserStackSidebarSectionState in
            var next = section
            next.workspaceIds = section.workspaceIds.filter { id in
                guard liveIds.contains(id), !seen.contains(id) else { return false }
                seen.insert(id)
                return true
            }
            return next
        }

        ensureRequiredSections(in: &nextSections)
        let newIds = snapshot.workspaceIds.filter { !seen.contains($0) }
        if !newIds.isEmpty {
            let targetIndex = nextSections.firstIndex { $0.id == BrowserStackSidebarSectionState.looseSectionId }
                ?? nextSections.startIndex
            nextSections[targetIndex].workspaceIds.append(contentsOf: newIds)
        }

        return BrowserStackSidebarState(sections: nextSections)
    }

    public mutating func moveWorkspace(_ move: CmuxSidebarProviderWorkspaceMove) {
        for index in sections.indices {
            sections[index].workspaceIds.removeAll { $0 == move.workspaceId }
        }

        let sectionIndex: Int
        if let existing = sections.firstIndex(where: { $0.id == move.targetSectionId }) {
            sectionIndex = existing
        } else {
            sections.append(
                BrowserStackSidebarSectionState(
                    id: move.targetSectionId,
                    title: BrowserStackSidebarSectionState.title(for: move.targetSectionId),
                    kind: .group,
                    workspaceIds: []
                )
            )
            sectionIndex = sections.index(before: sections.endIndex)
        }

        let insertionIndex = min(max(move.targetIndex, 0), sections[sectionIndex].workspaceIds.count)
        sections[sectionIndex].workspaceIds.insert(move.workspaceId, at: insertionIndex)
    }

    private func ensureRequiredSections(in sections: inout [BrowserStackSidebarSectionState]) {
        if !sections.contains(where: { $0.id == BrowserStackSidebarSectionState.tilesSectionId }) {
            sections.insert(
                BrowserStackSidebarSectionState(
                    id: BrowserStackSidebarSectionState.tilesSectionId,
                    title: "Pinned",
                    kind: .tiles,
                    workspaceIds: []
                ),
                at: sections.startIndex
            )
        }
        if !sections.contains(where: { $0.id == BrowserStackSidebarSectionState.looseSectionId }) {
            let insertionIndex = min(sections.count, 1)
            sections.insert(
                BrowserStackSidebarSectionState(
                    id: BrowserStackSidebarSectionState.looseSectionId,
                    title: "Open",
                    kind: .loose,
                    workspaceIds: []
                ),
                at: insertionIndex
            )
        }
    }
}

public struct BrowserStackSidebarSectionState: Codable, Equatable, Identifiable, Sendable {
    public static let tilesSectionId = "tiles"
    public static let looseSectionId = "loose"

    public var id: String
    public var title: String
    public var kind: Kind
    public var workspaceIds: [UUID]
    public var isExpanded: Bool

    public init(
        id: String,
        title: String,
        kind: Kind,
        workspaceIds: [UUID],
        isExpanded: Bool = true
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.workspaceIds = workspaceIds
        self.isExpanded = isExpanded
    }

    public var systemImageName: String {
        switch kind {
        case .tiles:
            return "rectangle.grid.3x2"
        case .loose:
            return "globe"
        case .group:
            return "folder"
        }
    }

    public static func title(for sectionId: String) -> String {
        if sectionId == tilesSectionId { return "Pinned" }
        if sectionId == looseSectionId { return "Open" }
        if sectionId.hasPrefix("group:") {
            return String(sectionId.dropFirst("group:".count))
        }
        return sectionId
    }

    public enum Kind: String, Codable, Equatable, Sendable {
        case tiles
        case loose
        case group
    }
}
