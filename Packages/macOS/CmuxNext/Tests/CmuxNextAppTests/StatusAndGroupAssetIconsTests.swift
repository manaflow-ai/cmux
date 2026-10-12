import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
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
    func sections(asset: (String) -> SidebarFavicon?) -> [SidebarRowSection] {
        let store = DaemonStore()
        let group = WorkspaceGroupID(rawValue: "g1")
        store.apply(snapshot: DaemonTree(
            workspaces: [WorkspaceSnapshot(id: 1, key: nil, resourceID: Self.workspace, name: "build", group: group)],
            groups: [WorkspaceGroupSnapshot(id: group, name: "Work", icon: Self.icon)]))
        var mirror = SessionStateMirror()
        mirror.workspaceStatus[Self.workspace] = WorkspaceStatus(
            workspaceID: Self.workspace, entries: [WorkspaceStatus.Entry(key: "build", text: "Building", icon: Self.icon)])
        store.session.apply(.snapshot(mirror), to: store.workspaces)
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local),
                                              iconAsset: asset)
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
}
