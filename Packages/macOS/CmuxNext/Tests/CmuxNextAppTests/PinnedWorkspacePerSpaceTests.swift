import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Pinned workspaces are per space (Lawrence 14223, from Austin: a pinned row clicked in one
/// space jumped the window to another). The pinned band is one document for every space; a window
/// draws a band workspace only while its current space shows that workspace, the same rule as the
/// workspace list (plans/cmux-next/spaces-overhaul-DESIGN.md rule 1).
@MainActor @Suite(.serialized)
struct PinnedWorkspacePerSpaceTests {
    static let work = ProfileID(rawValue: "prof_work"), play = ProfileID(rawValue: "prof_play")
    static let inWork = "s-local:ws_work", inPlay = "s-local:ws_play", closed = "s-local:ws_closed"

    /// A home store with spaces Work and Play: ws_work is pinned to Work, ws_play to Play.
    static func services(pinPlayTo playRoom: ProfileID = play) throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let keys = ["work", "play"], rooms = [work, playRoom]
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key),
                              resourceID: ResourceID(rawValue: "ws_\(key)"), name: key, screens: [])
        })
        tree.personal = PersonalState(
            sessions: [SessionRecord(id: "s-local")],
            profiles: [work, play].enumerated().map { ProfileSnapshot(id: $1, name: "Space \($0)", index: $0) },
            pins: keys.enumerated().map { WorkspacePin(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), profile: rooms[$0]) },
            workspaces: keys.enumerated().map { PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), index: $0) })
        store.apply(snapshot: tree)
        return services
    }

    static var document: SidebarLayoutDocument {
        var document = SidebarLayoutDocument.defaults
        let top = document.sections.firstIndex { $0.id == SidebarLayoutDocument.topSectionID }!
        let pins = [inWork, inPlay, closed].map { LayoutItem(id: LayoutItemID("itm_\($0)"), ref: .workspace($0), label: $0) }
        document.sections.insert(SidebarLayoutDocument.pinnedSection(items: pins), at: top + 1)
        return document
    }

    static func pinned(_ room: ProfileID, _ services: AppServices) -> [LayoutItemRef] {
        let hides = SidebarRows.bandHides(window: "w1", profile: room, machines: services.machines, registry: services.windows.registry.value)
        return document.scopedToWindow(ownedElsewhere: hides).section(SidebarLayoutDocument.pinnedSectionID)?.items.map(\.ref) ?? []
    }

    @Test func aSpaceDrawsOnlyItsOwnPinnedWorkspaces() throws {
        let services = try Self.services()
        // A closed workspace's pin has no space to be in: it draws (dimmed) everywhere, as before.
        #expect(Self.pinned(Self.work, services) == [.workspace(Self.inWork), .workspace(Self.closed)])
        #expect(Self.pinned(Self.play, services) == [.workspace(Self.inPlay), .workspace(Self.closed)])
    }

    /// Moving a workspace to another space moves its pin with it: the pin is not stored per space.
    @Test func movingAWorkspaceToAnotherSpaceMovesItsPin() throws {
        let services = try Self.services(pinPlayTo: Self.work)
        #expect(Self.pinned(Self.work, services) == [.workspace(Self.inWork), .workspace(Self.inPlay), .workspace(Self.closed)])
        #expect(Self.pinned(Self.play, services) == [.workspace(Self.closed)])
    }

    /// No space given (a caller that does not know the window's space): only window ownership scopes.
    @Test func withoutASpaceEveryPinDraws() throws {
        let services = try Self.services()
        let hides = SidebarRows.bandHides(window: "w1", profile: nil, machines: services.machines, registry: services.windows.registry.value)
        #expect(Self.document.scopedToWindow(ownedElsewhere: hides) == Self.document)
    }
}
