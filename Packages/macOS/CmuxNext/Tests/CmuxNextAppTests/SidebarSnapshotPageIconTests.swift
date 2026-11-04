import CoreGraphics
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo (relaunch after a nightly update): "i feel like the restarted after nightly update does too many layout
/// shifts/flicker renderings". A browser workspace's row came back from the saved sidebar with no icon, so its
/// title drew at the row inset in the first frame and moved right by the icon column when the live favicon came.
/// The snapshot keeps the page's icon slot: the restored row draws the placeholder globe in the column, and the
/// favicon replaces it in place.
@MainActor @Suite
struct SidebarSnapshotPageIconTests {
    private static func favicon() -> SidebarFavicon {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return SidebarFavicon(context.makeImage()!)
    }

    private static func restored(_ rows: [SidebarWorkspace]) throws -> [String: WorkspaceIcon?] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let saved = SidebarSnapshot(sections: [SidebarSection(kind: .machine(machine), nodes: rows.map(SidebarNode.workspace))],
                                    profiles: [], activeProfileID: nil)
        let decoded = try JSONDecoder().decode(SidebarSnapshot.self, from: JSONEncoder().encode(saved))
        var icons: [String: WorkspaceIcon?] = [:]
        for case let .workspace(ws) in decoded.sidebarSections.flatMap(\.nodes) { icons[ws.id.rawValue] = ws.icon }
        return icons
    }

    @Test func aPageRowRestoresWithItsIconColumn() throws {
        let icons = try Self.restored([
            SidebarWorkspace(id: WorkspaceID("site"), title: "site", icon: .favicon(Self.favicon()), kind: .browser),
            SidebarWorkspace(id: WorkspaceID("globe"), title: "globe", icon: .pagePlaceholder, kind: .browser),
            SidebarWorkspace(id: WorkspaceID("chosen"), title: "chosen", icon: .symbol("star"), kind: .browser),
            SidebarWorkspace(id: WorkspaceID("text"), title: "text"),
        ])
        #expect(icons["site"] == .some(.pagePlaceholder))
        #expect(icons["globe"] == .some(.pagePlaceholder))
        #expect(icons["chosen"] == .some(.symbol("star")))
        #expect(icons["text"] == .some(nil))
    }

    @Test func anOlderSnapshotWithoutThePageSlotStillReads() throws {
        let json = #"{"sections":[{"isCollapsed":false,"machineID":"local","machineKind":"local","nodes":[{"workspace":{"id":"w","machineID":"local","title":"w","kind":"browser"}}]}],"profiles":[]}"#
        let decoded = try JSONDecoder().decode(SidebarSnapshot.self, from: Data(json.utf8))
        guard case let .workspace(ws)? = decoded.sidebarSections.first?.nodes.first else { Issue.record("no row"); return }
        #expect(ws.icon == nil)
    }
}
