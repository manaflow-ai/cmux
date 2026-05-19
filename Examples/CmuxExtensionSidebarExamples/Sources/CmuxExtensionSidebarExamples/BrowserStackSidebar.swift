import CmuxExtensionKit
import Foundation

public struct BrowserStackSidebar: CmuxExtensionSidebarMutableProvider {
    public let descriptor = CmuxExtensionSidebarProviderDescriptor(
        id: "com.example.cmux.sidebar.browser-stack",
        title: localized("example.sidebar.browserStack.title", "Browser Stack"),
        subtitle: localized("example.sidebar.browserStack.subtitle", "User extension"),
        systemImageName: "square.on.square",
        isHostProvided: false
    )
    private let store: BrowserStackSidebarStore

    public init(store: BrowserStackSidebarStore = BrowserStackSidebarStore()) {
        self.store = store
    }

    public func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel {
        let state = (try? store.reconciledState(for: snapshot)) ?? BrowserStackSidebarState.initial(snapshot: snapshot)
        try? store.save(state)
        let workspacesById = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.id, $0) })
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
        _ mutation: CmuxExtensionSidebarMutation,
        snapshot: CmuxExtensionSidebarSnapshot
    ) throws -> CmuxExtensionCommandResult {
        guard case .moveWorkspace(let move) = mutation else {
            return CmuxExtensionCommandResult(ok: false)
        }
        try store.moveWorkspace(move, snapshot: snapshot)
        return CmuxExtensionCommandResult(ok: true)
    }

    private func recentActivityText(_ workspace: CmuxExtensionWorkspaceSnapshot) -> CmuxExtensionSidebarRenderText? {
        workspace.latestSubmittedAt.map { .relativeDate($0, style: .compact) }
    }

    private func browserIcon(_ workspace: CmuxExtensionWorkspaceSnapshot) -> CmuxExtensionSidebarRenderIcon? {
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if title.contains("google") {
            return CmuxExtensionSidebarRenderIcon(
                text: "G",
                foregroundColorHex: "#4285F4",
                backgroundColorHex: "#FFFFFF"
            )
        }
        if title.contains("hacker") || title.contains("ycombinator") || title.contains("yc") {
            return CmuxExtensionSidebarRenderIcon(
                text: "Y",
                foregroundColorHex: "#FFFFFF",
                backgroundColorHex: "#FF6600",
                shape: .roundedRectangle
            )
        }
        if title == "x" || title.hasPrefix("x.") || title.contains("twitter") || title.contains("what's happening") {
            return CmuxExtensionSidebarRenderIcon(
                text: "X",
                foregroundColorHex: "#FFFFFF",
                backgroundColorHex: "#000000",
                shape: .roundedRectangle
            )
        }
        if title.contains("dia") || workspace.unreadCount > 0 {
            return CmuxExtensionSidebarRenderIcon(
                systemImageName: "bubble.left.fill",
                foregroundColorHex: "#D8D8D8",
                backgroundColorHex: "#000000"
            )
        }
        return CmuxExtensionSidebarRenderIcon(
            systemImageName: "bubble.left.fill",
            foregroundColorHex: "#D0D0D0",
            backgroundColorHex: "#5A5A5A"
        )
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
        let data = try Data(contentsOf: stateURL)
        return try JSONDecoder().decode(BrowserStackSidebarState.self, from: data)
    }

    public func save(_ state: BrowserStackSidebarState) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: [.atomic])
    }

    public func reconciledState(for snapshot: CmuxExtensionSidebarSnapshot) throws -> BrowserStackSidebarState {
        let loaded = (try? load()) ?? BrowserStackSidebarState.initial(snapshot: snapshot)
        return loaded.reconciled(with: snapshot)
    }

    public func moveWorkspace(
        _ move: CmuxExtensionSidebarWorkspaceMove,
        snapshot: CmuxExtensionSidebarSnapshot
    ) throws {
        var state = try reconciledState(for: snapshot)
        state.moveWorkspace(move)
        try save(state.reconciled(with: snapshot))
    }
}

public struct BrowserStackSidebarState: Codable, Equatable, Sendable {
    public var sections: [BrowserStackSidebarSectionState]

    public init(sections: [BrowserStackSidebarSectionState]) {
        self.sections = sections
    }

    public static func initial(snapshot: CmuxExtensionSidebarSnapshot) -> BrowserStackSidebarState {
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

    public func reconciled(with snapshot: CmuxExtensionSidebarSnapshot) -> BrowserStackSidebarState {
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

    public mutating func moveWorkspace(_ move: CmuxExtensionSidebarWorkspaceMove) {
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
