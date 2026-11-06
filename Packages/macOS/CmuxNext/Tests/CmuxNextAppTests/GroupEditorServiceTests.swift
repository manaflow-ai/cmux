import AppKit
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The sidebar's group editor is the React page webviews/src/pages/group-editor in one warm panel
/// (GroupEditorService). Group editors are menus (#26400, #27056): the card shows in one step, fully
/// drawn, once the page has painted the group, never fading or growing in; a typed name commits when
/// the editor closes; a call from an earlier open edits nothing.
@MainActor @Suite(.serialized, .closesItsWindows) struct GroupEditorServiceTests {
    final class Record {
        var renames: [String] = []
        var colors: [GroupColor] = []
        var items: [String] = []
        var closes = 0
    }

    static func events(_ record: Record) -> SidebarGroupEditorEvents {
        SidebarGroupEditorEvents(rename: { record.renames.append($0) }, color: { record.colors.append($0) }, customColor: {},
                                 item: { record.items.append($0) }, close: { record.closes += 1 })
    }

    static let group = SidebarGroup(id: GroupID("g-work"), name: "Work", color: .blue, workspaces: [])
    static let items = [[SidebarGroupEditorItem(id: "workspaceGroup.newWorkspace", title: "New Workspace in Group", icon: .workspaceNew)], []]

    @Test func theSessionCarriesTheDotsTheRowsAndTheChosenColor() throws {
        let session = GroupEditorSession(id: "s1", revision: 3, group: Self.group, items: Self.items)
        let event = session.event(themed: false, icons: GroupEditorIcons())
        #expect(event["id"]?.stringValue == "s1")
        #expect(event["revision"]?.intValue == 3)
        #expect(event["name"]?.stringValue == "Work")
        let colors = try #require(event["colors"].flatMap { if case let .array(values) = $0 { values } else { nil } })
        #expect(colors.compactMap { $0["id"]?.stringValue } == GroupColor.editorOrder.map(\.rawValue))
        #expect(colors.filter { $0["chosen"]?.boolValue == true }.compactMap { $0["id"]?.stringValue } == ["blue"])
        #expect(colors.first?["outlined"]?.boolValue == true, "the No color dot has its edge")
        guard case let .array(sections)? = event["sections"] else { Issue.record("no sections"); return }
        #expect(sections.count == 1, "an empty section draws no separator")
        guard case let .array(rows) = sections[0] else { Issue.record("no rows"); return }
        #expect(rows.first?["icon"]?.stringValue?.hasPrefix("data:image/png;base64,") == true, "the row's icon comes with the session")

        var none = Self.group
        none.tint = .none
        let cleared = GroupEditorSession(id: "s2", revision: 1, group: none, items: []).event(themed: false, icons: GroupEditorIcons())
        guard case let .array(dots)? = cleared["colors"] else { Issue.record("no colors"); return }
        #expect(dots.filter { $0["chosen"]?.boolValue == true }.compactMap { $0["id"]?.stringValue } == ["grey"],
                "a group with no color shows the No color dot chosen")
    }

    @Test func aCallFromAnotherOpenEditsNothing() async throws {
        let provider = GroupEditorProvider()
        var calls: [GroupEditorProvider.Call] = []
        provider.onCall = { calls.append($0) }
        provider.openSession = "s2"
        let context = PageCallContext(page: PageDescriptor.groupEditor.id)
        _ = try await provider.call("cmux.groupEditor.item", params: .object(["session": .string("s1"), "item": .string("x")]), context: context)
        _ = try await provider.call("cmux.groupEditor.color", params: .object(["session": .string("s2"), "color": .string("red")]), context: context)
        #expect(calls == [.color("red")])
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.groupEditor.ready", params: .object(["session": .string("s2")]), context: context)
        }
    }

    @Test func aTypedNameCommitsWhenTheEditorCloses() throws {
        let service = GroupEditorService()
        let record = Record()
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.closeAfterTest() }
        service.present(Self.group, items: Self.items, anchor: PopupAnchor(rect: CGRect(x: 240, y: 650, width: 100, height: 30), edge: .leading),
                        parent: parent, themeAnchor: parent.contentView ?? NSView(), ordersFront: false, events: Self.events(record))
        let provider = try #require(service.provider)
        #expect(provider.event?["name"]?.stringValue == "Work")
        provider.onCall?(.draft("  Docs  "))
        provider.onCall?(.color("red"))
        service.dismiss()
        #expect(record.colors == [.red])
        #expect(record.renames == ["Docs"])
        #expect(record.closes == 1)
        service.dismiss()
        #expect(record.closes == 1, "a second close reports nothing")
    }

    /// Review of #37299 (F1): a name changed elsewhere while the field is untouched is not written back on close.
    @Test func anUntouchedFieldLeavesANameChangedElsewhere() throws {
        let service = GroupEditorService()
        let record = Record()
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.closeAfterTest() }
        service.present(Self.group, items: Self.items, anchor: PopupAnchor(rect: CGRect(x: 240, y: 650, width: 100, height: 30), edge: .leading),
                        parent: parent, themeAnchor: parent.contentView ?? NSView(), ordersFront: false, events: Self.events(record))
        var renamed = Self.group
        renamed.name = "Office"
        service.refresh(renamed)
        service.dismiss()
        #expect(record.renames.isEmpty, "closing an untouched editor renamed the group back")
    }

    @Test func theCardShowsInOneStepOnceThePageHasPainted() async throws {
        try #require(await GUIAnimationTestSupport.animatesHere(), "requires an awake fleet display; a skip is not regression evidence")
        let service = GroupEditorService()
        let record = Record()
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        defer { parent.closeAfterTest() }
        let anchor = PopupAnchor(rect: CGRect(x: 240, y: 650, width: 100, height: 30), edge: .leading)
        service.present(Self.group, items: Self.items, anchor: anchor, parent: parent, themeAnchor: parent.contentView ?? NSView(),
                        ordersFront: true, events: Self.events(record))
        let panel = try #require(service.panel)
        defer { panel.closeAfterTest() }
        #expect(panel.isVisible, "the panel is in its window so the page paints")
        #expect(panel.ignoresMouseEvents, "a card not shown yet takes no click")
        #expect(service.open?.shown == false)

        service.provider?.onCall?(.ready(revision: 1, height: 300))
        #expect(service.open?.shown == true)
        #expect(!panel.ignoresMouseEvents)
        let card = PopupStyle.standard.cardFrame(inWindow: panel.frame)
        #expect(abs(card.height - 300) <= 0.5, "the card is the page's height")
        #expect(card == SidebarGroupEditor.cardFrame(anchor: anchor, parent: parent, height: 300))
        let layer = try #require(panel.contentView?.layer)
        #expect(layer.animation(forKey: "opacity") == nil, "opening must not fade in")
        #expect(layer.animation(forKey: "sublayerTransform") == nil, "opening must not grow in")

        // A stale ready (an earlier revision) moves nothing.
        service.refresh(Self.group)
        service.provider?.onCall?(.ready(revision: 1, height: 500))
        #expect(abs(PopupStyle.standard.cardFrame(inWindow: panel.frame).height - 300) <= 0.5)
        service.dismiss()
        #expect(record.closes == 1)
    }
}
