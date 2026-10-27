import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBridgeUI
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A stored image or SVG icon (`icon-assets-v1`) on a workspace status entry
/// (`cmux workspace status set --icon`) draws in the row's status block and in the hover card,
/// and a workspace group's stored icon draws in its header (cx-qno.11.1). Until the asset is
/// read an entry draws its text alone and a group the placeholder.
@MainActor
struct StatusAndGroupAssetIconsTests {
    static let icon = "svg:sha256-" + String(repeating: "c", count: 64)
    static let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z" fill="#2a2"></path></svg>"##.utf8)
    static let workspace = ResourceID(rawValue: "ws-status")

    /// The sidebar sections of one grouped workspace reporting a status entry, with the group
    /// and the entry both naming the stored icon.
    func sections(asset: @escaping (String) -> SidebarFavicon?, groupAsset: ((String) -> SidebarFavicon?)? = nil,
                  extraEntries: Int = 0) -> [SidebarRowSection] {
        let store = DaemonStore()
        let group = WorkspaceGroupID(rawValue: "g1")
        store.apply(snapshot: DaemonTree(
            workspaces: [WorkspaceSnapshot(id: 1, key: nil, resourceID: Self.workspace, name: "build", group: group)],
            groups: [WorkspaceGroupSnapshot(id: group, name: "Work", icon: Self.icon)]))
        var mirror = SessionStateMirror()
        mirror.workspaceStatus[Self.workspace] = WorkspaceStatus(
            workspaceID: Self.workspace,
            entries: [WorkspaceStatus.Entry(key: "build", text: "Building", icon: Self.icon)]
                + (0..<extraEntries).map { WorkspaceStatus.Entry(key: "k\($0)", text: "entry \($0)") })
        store.session.apply(.snapshot(mirror), in: store)
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local),
                                              iconAsset: asset, groupIconAsset: groupAsset)
    }

    func group(_ sections: [SidebarRowSection]) -> SidebarGroup? {
        sections.flatMap(\.nodes).lazy.compactMap { node -> SidebarGroup? in
            if case .group(let group) = node { group } else { nil }
        }.first
    }

    @Test func aStatusEntryAndAGroupDrawTheirStoredIcons() throws {
        let favicon = SidebarFavicon(try #require(IconAssetImages.decode(Self.svg, mediaType: "image/svg+xml")))
        let drawn = sections(asset: { $0 == Self.icon ? favicon : nil })
        let row = try #require(drawn.flatMap(\.workspaces).first)
        #expect(row.reported?.entries.first?.image == favicon)
        #expect(group(drawn)?.icon == .favicon(favicon))

        let card = WorkspaceHoverCardContent.make(row, machine: nil, now: Date())
        let fact = try #require(card.facts.first { $0.text == "Building" }, "the hover card lists the status entry")
        #expect(fact.image == favicon)

        let loading = sections(asset: { _ in nil })
        #expect(loading.flatMap(\.workspaces).first?.reported?.entries.first?.image == nil)
        #expect(group(loading)?.icon != .favicon(favicon))
    }

    /// A personal group's icon is the home daemon's (whichever machine's section shows the group);
    /// a status entry's is its workspace's daemon's.
    @Test func aGroupReadsItsIconFromTheHomeDaemon() throws {
        let favicon = SidebarFavicon(try #require(IconAssetImages.decode(Self.svg, mediaType: "image/svg+xml")))
        let drawn = sections(asset: { _ in nil }, groupAsset: { $0 == Self.icon ? favicon : nil })
        #expect(group(drawn)?.icon == .favicon(favicon))
        #expect(drawn.flatMap(\.workspaces).first?.reported?.entries.first?.image == nil)
    }

    /// The hover card lists as many status entries as the row does, then how many more.
    @Test func theHoverCardFoldsStatusEntriesPastTheRowsLimit() throws {
        let row = try #require(sections(asset: { _ in nil }, extraEntries: 9).flatMap(\.workspaces).first)
        let texts = WorkspaceHoverCardContent.make(row, machine: nil, now: Date()).facts.map(\.text)
        let limit = SidebarWorkspaceStatus.visibleEntryLimit
        #expect(texts.filter { $0 == "Building" || $0.hasPrefix("entry ") }.count == limit)
        #expect(texts.last == CmuxNextSidebar.Strings.statusMore(10 - limit))
    }
}
