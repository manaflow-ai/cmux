import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Foundation
import Testing

/// David Beyer's feedback (2026-11-20): the Chief is a thread in the sidebar, not only Home's first conversation. Its
/// row comes in under Home once per Mac, Add to Sidebar puts it there too, and it is the selected row while Home
/// shows the Chief's conversation (Home's row for any other one), as a thread's row is selected while its chat shows.
@MainActor @Suite(.serialized)
struct ChiefSidebarThreadTests {
    static let chief = LayoutItemRef.builtIn(.chief)

    static func topRefs(_ document: SidebarLayoutDocument) -> [LayoutItemRef] {
        document.sections.filter { $0.region == .top }.flatMap(\.items).map(\.ref)
    }

    static func applying(_ op: SidebarLayoutOp?, to document: SidebarLayoutDocument) throws -> SidebarLayoutDocument {
        let op = try #require(op, "no op to add the Chief")
        guard case .success(let next) = SidebarLayoutReducer.reduce(document, op) else {
            Issue.record("the layout refused the Chief's add")
            return document
        }
        return next
    }

    /// The default sidebar (Home, the App Store): the Chief goes right under Home, not above it at the top.
    @Test func addToSidebarPutsTheChiefRightUnderHome() throws {
        let home = SidebarLayoutDocument.homeRef
        let op = SidebarLayoutPlanner.add(Self.chief, in: .defaults, newItem: SidebarLayoutDocument.chiefItemID)
        let added = try Self.applying(op, to: .defaults)
        #expect(Self.topRefs(added) == [home, Self.chief, .app("cmux/app-store")], "the Chief is not right under Home: \(Self.topRefs(added))")
        #expect(added.item(SidebarLayoutDocument.chiefItemID)?.ref == Self.chief, "the Chief does not carry its own item id")
        #expect(SidebarLayoutPlanner.add(Self.chief, in: added) == nil, "a second Chief was offered")
    }

    /// A sidebar the person took Home out of: the Chief still goes to the top rows.
    @Test func withoutHomeTheChiefGoesToTheTop() throws {
        var document = SidebarLayoutDocument.defaults
        document.sections[0].items.removeAll { $0.ref == SidebarLayoutDocument.homeRef }
        let added = try Self.applying(SidebarLayoutPlanner.add(Self.chief, in: document), to: document)
        #expect(Self.topRefs(added).first == Self.chief, "with no Home the Chief did not go to the top: \(Self.topRefs(added))")
    }

    /// Once per Mac: the first loaded document without a Chief gets one; after that, a Chief the person removed stays
    /// out, and a document that already placed one is never given a second.
    @Test func theChiefRowIsOfferedOncePerMac() throws {
        let suite = "cmux-chief-row-offer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let offer = ChiefSidebarOffer(defaults: defaults)
        #expect(offer.shouldAdd(placed: false), "a first document without the Chief did not get it")
        #expect(!offer.shouldAdd(placed: false), "the Chief the person removed came back")

        let other = try #require(UserDefaults(suiteName: suite + "-placed"))
        defer { other.removePersistentDomain(forName: suite + "-placed") }
        let placedFirst = ChiefSidebarOffer(defaults: other)
        #expect(!placedFirst.shouldAdd(placed: true), "a document that places the Chief was given a second")
        #expect(!placedFirst.shouldAdd(placed: false), "a Chief removed after the first load came back")
    }

    /// The window shows its Home: the Chief's row is selected while Home shows the Chief's conversation, Home's row
    /// for any other conversation.
    @Test func theChiefRowIsSelectedWhileHomeShowsTheChief() throws {
        let layout = try Self.applying(SidebarLayoutPlanner.add(Self.chief, in: .defaults, newItem: SidebarLayoutDocument.chiefItemID),
                                       to: .defaults)
        let onChief = SidebarNavigation.selectedItem(page: nil, workspace: "ws-home", layout: layout, home: "ws-home", chief: true)
        #expect(onChief == .topItem(SidebarLayoutDocument.chiefItemID), "Home on the Chief's conversation selects \(String(describing: onChief))")
        let onOther = SidebarNavigation.selectedItem(page: nil, workspace: "ws-home", layout: layout, home: "ws-home", chief: false)
        #expect(onOther == .topItem(LayoutItemID("itm_home")), "Home on another conversation selects \(String(describing: onOther))")
        let elsewhere = SidebarNavigation.selectedItem(page: nil, workspace: "ws-app", layout: layout, home: "ws-home", chief: true)
        #expect(elsewhere == .workspace(WorkspaceID("ws-app")), "another workspace selects \(String(describing: elsewhere))")
    }

    /// What Home shows drives the Chief row's selection: the Chief's conversation sets it, any other clears it.
    @Test func homeShowingTheChiefsConversationIsFollowed() {
        let sidebar = ChiefSidebar(lanes: AgentLaneStore(), host: .init(conversation: { "c-chief" }, chiefHost: { nil }, tab: { _, _ in nil },
                                                                       reveal: { _ in false }, openWorkspace: { _, _ in ActionWork { nil } }))
        sidebar.homeShowed("c-chief")
        #expect(sidebar.homeShowsChief, "Home showing the Chief's conversation is not followed")
        sidebar.homeShowed("c-team")
        #expect(!sidebar.homeShowsChief, "Home showing another conversation still counts as the Chief")
        sidebar.homeShowed(nil)
        #expect(!sidebar.homeShowsChief)
    }
}
