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
        let event = session.event(palette: .glass, icons: GroupEditorIcons())
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
        let cleared = GroupEditorSession(id: "s2", revision: 1, group: none, items: []).event(palette: .glass, icons: GroupEditorIcons())
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

    /// Review of #37299 (F2): a closed editor leaves no session for a page that reloads.
    @Test func aClosedEditorLeavesNoSessionForAReload() async throws {
        let service = GroupEditorService()
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.closeAfterTest() }
        service.present(Self.group, items: Self.items, anchor: PopupAnchor(rect: CGRect(x: 240, y: 650, width: 100, height: 30), edge: .leading),
                        parent: parent, themeAnchor: parent.contentView ?? NSView(), ordersFront: false, events: Self.events(Record()))
        service.dismiss()
        let provider = try #require(service.provider)
        var first: JSONValue?
        _ = try await provider.subscribe(GroupEditorProvider.sessionStream, filter: .object([:]),
                                         context: PageCallContext(page: PageDescriptor.groupEditor.id)) { first = first ?? $0 }
        #expect(first?["id"]?.stringValue == "", "a reload after the close drew the closed editor again")
    }

    /// Review of #37299 at a9e3400 (F1), and of #37274 at ae317df (F1): the page's controls are fixed CSS sizes times
    /// its `--cmux-interface-scale` (`Typography.pageScale`), so the card is 240 times that at every density: wider at
    /// Spacious, whose 14.5 pt text grows the page, and never narrower than 240 at the smaller ones.
    @Test func theCardMatchesItsPageScaleAtEveryDensity() {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.overrides[.chromeFontSize])
        defer {
            design.densityTokens = saved.0
            design.setOverride(.chromeFontSize, saved.1)
        }
        design.setOverride(.chromeFontSize, nil)
        for density in design.availableDensities {
            design.densityTokens = density
            let standard = 240 * Typography.pageScale
            #expect(abs(SidebarGroupEditor.width - standard) <= 0.5,
                    "the editor is \(SidebarGroupEditor.width) wide at density \(density.id); its page's controls need \(standard)")
            #expect(SidebarGroupEditor.width >= 239.5, "the editor shrank to \(SidebarGroupEditor.width) at density \(density.id)")
        }
        design.densityTokens = DensityPreset.spacious.tokens
        #expect(SidebarGroupEditor.width > 250, "Spacious grows the page's controls, the editor stayed \(SidebarGroupEditor.width) wide")
    }

    /// Review of #37299 at efa6302 (F1), and of #37274 at ae317df (F1): the card follows the page's Text Size scale
    /// (`Typography.pageScale`), which grows past the Default body size and stays 1 below it, so a small Text Size
    /// keeps the card 240 wide for controls drawn at 1x.
    @Test func theCardFollowsTheTextSizeLikeItsPage() {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.overrides[.chromeFontSize])
        defer {
            design.densityTokens = saved.0
            design.setOverride(.chromeFontSize, saved.1)
        }
        design.densityTokens = DensityPreset.compact.tokens
        design.setOverride(.chromeFontSize, 11)
        #expect(abs(SidebarGroupEditor.width - 240) <= 0.5, "a Text Size below 13 pt draws the page at 1x; the card is \(SidebarGroupEditor.width)")
        design.setOverride(.chromeFontSize, 16)
        #expect(Typography.pageScale > 1, "the test's Text Size did not enlarge the page")
        #expect(abs(SidebarGroupEditor.width - 240 * Typography.pageScale) <= 0.5,
                "the card stayed \(SidebarGroupEditor.width) wide for controls scaled \(Typography.pageScale)x")
    }

    /// Review of #37299 at efa6302 (F2): the editor takes the keys as it opens, before the page has painted, so a name
    /// typed right after Rename Group goes into its field, not into the list or terminal under it; and (review at 9c0b58c,
    /// F1) a close before the page answers gives them back. A test app is not the active app, so no window of it becomes
    /// key (`ActiveAppKeyPanel`); what the editor controls, and what this checks, is that the page holds the panel's
    /// first responder from the open on, and nothing in the panel does after the close.
    @Test func theEditorTakesTheKeysAsItOpens() async throws {
        try #require(await GUIAnimationTestSupport.animatesHere(), "requires an awake fleet display; a skip is not regression evidence")
        let service = GroupEditorService()
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        defer { parent.closeAfterTest() }
        service.present(Self.group, items: Self.items, anchor: PopupAnchor(rect: CGRect(x: 240, y: 650, width: 100, height: 30), edge: .leading),
                        parent: parent, themeAnchor: parent.contentView ?? NSView(), ordersFront: true, events: Self.events(Record()))
        let panel = try #require(service.panel)
        defer { panel.closeAfterTest() }
        let content = try #require(panel.contentView)
        #expect(service.open?.shown == false, "the page has not answered yet")
        let focused = panel.firstResponder as? NSView
        #expect(focused.map { $0 !== content && $0.isDescendant(of: content) } == true,
                "the page did not hold the keyboard before it painted: \(String(describing: panel.firstResponder))")
        service.dismiss()
        #expect(panel.firstResponder === panel, "the closed, invisible editor's page kept the keyboard")
    }

    /// Review of #37299 at 44de463 (F1): the page zooms with `app.uiScale`, so its CSS pixels are not points; the card
    /// is the page's height and the editor's width at that zoom, so nothing under the swatches is cut off.
    @Test func theCardFollowsThePageZoom() throws {
        let design = DesignSettings.shared
        let saved = design.uiScale
        design.uiScale = 1.5
        defer { design.uiScale = saved }
        let service = GroupEditorService()
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.closeAfterTest() }
        let anchor = PopupAnchor(rect: CGRect(x: 240, y: 1000, width: 100, height: 30), edge: .leading)
        service.present(Self.group, items: Self.items, anchor: anchor, parent: parent, themeAnchor: parent.contentView ?? NSView(),
                        ordersFront: false, events: Self.events(Record()))
        service.provider?.onCall?(.ready(revision: 1, height: 300))
        let card = PopupStyle.standard.cardFrame(inWindow: service.frame(anchor: anchor, parent: parent))
        #expect(abs(card.height - 450) <= 0.5, "a 300 px page at 150% got a card \(card.height) points tall")
        #expect(abs(card.width - SidebarGroupEditor.width * 1.5) <= 0.5, "the zoomed swatch row is cut off at \(card.width) points")
        service.dismiss()
    }

    /// Review of #37299 at 44de463 (F2): a closed editor leaves no shadow over its window.
    @Test func aVeiledCardCastsNoShadow() {
        let panel = GroupEditorPanel(content: NSView(), width: SidebarGroupEditor.width)
        defer { panel.closeAfterTest() }
        panel.veil()
        #expect(!panel.castsShadow, "the closed editor's shadow stayed over the window")
    }

    /// Review of #37299 at c21ec81 (F1): the editor draws in the sidebar's theme at full strength, as the native
    /// bubble did, in each room it opens in, not in its own panel's or the last room's.
    @Test func theEditorDrawsInTheSidebarsTheme() throws {
        let service = GroupEditorService()
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.closeAfterTest() }
        let anchor = PopupAnchor(rect: CGRect(x: 240, y: 650, width: 100, height: 30), edge: .leading)
        for _ in 0 ..< 2 {
            let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
            let scope = ThemeScope(level: .room)
            scope.root(sidebar)
            service.present(Self.group, items: Self.items, anchor: anchor, parent: parent, themeAnchor: sidebar,
                            ordersFront: false, events: Self.events(Record()))
            let panel = try #require(service.panel)
            #expect(panel.themeScope === scope.fullStrength, "the editor drew outside the sidebar's theme")
            service.dismiss()
        }
    }

    /// Review of #37299 at d0f9d91 (F1): a page that reloads while the editor is open gets the typed name back,
    /// so the field shows what the close will commit.
    @Test func aReloadWhileOpenGetsTheTypedName() async throws {
        let service = GroupEditorService()
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.closeAfterTest() }
        service.present(Self.group, items: Self.items, anchor: PopupAnchor(rect: CGRect(x: 240, y: 650, width: 100, height: 30), edge: .leading),
                        parent: parent, themeAnchor: parent.contentView ?? NSView(), ordersFront: false, events: Self.events(Record()))
        let provider = try #require(service.provider)
        #expect(provider.event?["draft"] == .null, "an untouched field sends no draft")
        provider.onCall?(.draft("Docs"))
        var first: JSONValue?
        _ = try await provider.subscribe(GroupEditorProvider.sessionStream, filter: .object([:]),
                                         context: PageCallContext(page: PageDescriptor.groupEditor.id)) { first = first ?? $0 }
        #expect(first?["draft"]?.stringValue == "Docs", "a reload drew the group's name while the close commits the draft")
        var renamed = Self.group
        renamed.name = "Office"
        service.refresh(renamed)
        #expect(provider.event?["draft"]?.stringValue == "Docs", "a refresh dropped the draft")
        service.dismiss()
    }

    /// Review of #37299 (F1): between opens the panel stays in its window, its card transparent and click-through,
    /// so the page keeps painting and the next open shows at once.
    @Test func aClosedEditorStaysWarmInItsWindow() async throws {
        try #require(await GUIAnimationTestSupport.animatesHere(), "requires an awake fleet display; a skip is not regression evidence")
        let design = DesignSettings.shared
        let saved = design.animationsEnabled
        design.animationsEnabled = false
        defer { design.animationsEnabled = saved }
        let service = GroupEditorService()
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        defer { parent.closeAfterTest() }
        let anchor = PopupAnchor(rect: CGRect(x: 240, y: 650, width: 100, height: 30), edge: .leading)
        service.present(Self.group, items: Self.items, anchor: anchor, parent: parent, themeAnchor: parent.contentView ?? NSView(),
                        ordersFront: true, events: Self.events(Record()))
        let panel = try #require(service.panel as? GroupEditorPanel)
        defer { panel.closeAfterTest() }
        service.provider?.onCall?(.ready(revision: 1, height: 300))
        #expect(!panel.isVeiled)
        service.dismiss()
        #expect(panel.isVisible, "the closed editor left its window, so the page stops painting")
        #expect(panel.parent === parent)
        #expect(panel.isVeiled, "the closed editor's card still shows")
        #expect(panel.ignoresMouseEvents, "the closed editor's card takes clicks")
    }
}
