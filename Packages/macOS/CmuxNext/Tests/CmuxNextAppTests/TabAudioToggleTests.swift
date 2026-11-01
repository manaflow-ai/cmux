import AppKit
@testable import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

typealias TabAudioStripID = CmuxNextTabs.TabID

/// Lawrence 2026-10-19 (u1948, a85 follow-up): a tab playing sound mutes and unmutes from its
/// speaker, Chrome style; a sidebar workspace row shows a small speaker while any of its tabs
/// plays sound and a click on it mutes them all; Mute Tab, Unmute Tab and Mute Other Tabs are
/// commands in the palette, verbs of the CLI and tools of MCP.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabAudioToggleTests {
    final class StripHarness {
        let model: TabStripModel
        let strip: TabStripView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        private(set) var intents: [TabStripIntent] = []

        init(audio: TabAudio?) {
            var tabs = (0..<3).map { TabItem(id: TabAudioStripID("tab\($0)"), title: "A page with a long enough title \($0)") }
            tabs[1].audio = audio
            model = TabStripModel(tabs: tabs, selectedID: TabAudioStripID("tab0"))
            strip = TabStripView(model: model)
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
            window.contentView = strip
            window.orderFrontRegardless()
            strip.layoutSubtreeIfNeeded()
            model.intentHandler = { [unowned self] intent in intents.append(intent) }
        }

        /// The center of tab `id`'s speaker in window coordinates.
        func speaker(_ id: TabAudioStripID) throws -> CGPoint {
            let cell = try #require(strip.cells[id])
            let rect = try #require(cell.audioButtonRect, "tab \(id.rawValue) shows no speaker")
            let point = CGPoint(x: cell.frame.minX + rect.midX, y: cell.frame.minY + rect.midY)
            return strip.convert(strip.convert(point, from: strip.tabsClip), to: nil)
        }

        /// The left end of tab `id`'s title, in window coordinates (no speaker there).
        func body(_ id: TabAudioStripID) throws -> CGPoint {
            let cell = try #require(strip.cells[id])
            let point = CGPoint(x: cell.frame.minX + cell.frame.width * 0.3, y: cell.frame.midY)
            return strip.convert(strip.convert(point, from: strip.tabsClip), to: nil)
        }

        func click(_ point: CGPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                     pressure: type == .leftMouseUp ? 0 : 1) else { continue }
                window.sendEvent(event)
            }
        }

        var selects: Int { intents.filter { if case .select = $0 { true } else { false } }.count }
        var toggles: [TabAudioStripID] { intents.compactMap { if case .toggleAudioMute(let id) = $0 { id } else { nil } } }
    }

    // MARK: The strip's speaker

    /// A click on the speaker of a tab playing sound (or of a muted tab) asks once to mute or
    /// unmute it, and neither selects nor drags the tab (Chrome's alert indicator button).
    @Test(arguments: [TabAudio.playing, .muted])
    func clickingTheSpeakerTogglesMuteWithoutSelecting(_ audio: TabAudio) throws {
        let harness = StripHarness(audio: audio)
        defer { harness.window.closeAfterTest() }
        harness.click(try harness.speaker(TabAudioStripID("tab1")))
        #expect(harness.toggles == [TabAudioStripID("tab1")], "\(harness.intents)")
        #expect(harness.selects == 0, "the speaker click selected the tab")
    }

    /// The rest of the tab still selects it on the press.
    @Test func clickingTheTabBodyStillSelects() throws {
        let harness = StripHarness(audio: .playing)
        defer { harness.window.closeAfterTest() }
        harness.click(try harness.body(TabAudioStripID("tab1")))
        #expect(harness.toggles.isEmpty)
        #expect(harness.selects == 1)
    }

    /// A silent tab has no speaker to click.
    @Test func aSilentTabHasNoSpeaker() throws {
        let harness = StripHarness(audio: nil)
        defer { harness.window.closeAfterTest() }
        #expect(harness.strip.cells[TabAudioStripID("tab1")]?.audioButtonRect == nil)
    }

    /// The local reducer (the demo strip) swaps playing and muted.
    @Test func theLocalReducerSwapsPlayingAndMuted() {
        var item = TabItem(id: TabAudioStripID("t"), title: "t")
        item.audio = .playing
        let model = TabStripModel(tabs: [item], selectedID: TabAudioStripID("t"))
        #expect(model.apply(.toggleAudioMute(TabAudioStripID("t")), makeTab: { TabItem(id: TabAudioStripID("new"), title: "") }))
        #expect(model.tab(TabAudioStripID("t"))?.audio == .muted)
        model.apply(.toggleAudioMute(TabAudioStripID("t")), makeTab: { TabItem(id: TabAudioStripID("new"), title: "") })
        #expect(model.tab(TabAudioStripID("t"))?.audio == .playing)
    }

    // MARK: The sidebar row's speaker

    /// The row's speaker: playing while any tab plays sound, muted while none plays and one is
    /// muted, none while every tab is silent.
    @Test func theRowMergesItsTabsSound() {
        #expect(SidebarWorkspaceAudio.merge([nil, .muted, .playing]) == .playing)
        #expect(SidebarWorkspaceAudio.merge([nil, .muted]) == .muted)
        #expect(SidebarWorkspaceAudio.merge([nil, nil]) == nil)
        #expect(SidebarWorkspaceAudio.merge([]) == nil)
    }

    /// A click on a playing row mutes the playing tabs; on a muted row it unmutes the muted ones.
    @Test func aRowClickMutesThePlayingTabsOrUnmutesTheMutedOnes() {
        #expect(SidebarWorkspaceAudio.playing.change(for: .playing) == true)
        #expect(SidebarWorkspaceAudio.playing.change(for: .muted) == nil)
        #expect(SidebarWorkspaceAudio.playing.change(for: nil) == nil)
        #expect(SidebarWorkspaceAudio.muted.change(for: .muted) == false)
        #expect(SidebarWorkspaceAudio.muted.change(for: nil) == nil)
    }

    /// The mapped row carries its browser tabs' sound (`SidebarMapping.PageFace.audio`).
    @Test func theMappedRowCarriesItsBrowserTabsSound() throws {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, kind: .browser, url: "https://quiet.example"),
                                              TabSnapshot(surface: 2, kind: .browser, url: "https://music.example"),
                                              TabSnapshot(surface: 3, terminalResourceID: "term_1")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        let playing = SidebarMapping.shared.row(workspace, machine: .local, pageFace: { _, tab, _ in
            .init(audio: tab.url == "https://music.example" ? .playing : nil)
        })
        #expect(playing.audio == .playing)
        let silent = SidebarMapping.shared.row(workspace, machine: .local, pageFace: { _, _, _ in .init() })
        #expect(silent.audio == nil)
    }

    /// The row shows its speaker while the workspace has sound (always, not only on hover), and a
    /// click on it sends the workspace's toggle once; a silent workspace's row shows none.
    @Test(arguments: [SidebarWorkspaceAudio.playing, .muted])
    func theRowShowsASpeakerThatAsksToToggle(_ audio: SidebarWorkspaceAudio) throws {
        let loud = WorkspaceID("ws-loud"), quiet = WorkspaceID("ws-quiet")
        var loudRow = SidebarWorkspace(id: loud, title: "Music", kind: .browser)
        loudRow.audio = audio
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(loudRow), .workspace(SidebarWorkspace(id: quiet, title: "Notes", kind: .terminal)),
        ])])
        var sent: [SidebarIntent] = []
        model.onIntent = { sent.append($0) }
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        let row = try #require(sidebar.list.rowViews[.workspace(loud)] as? WorkspaceRowView)
        let silent = try #require(sidebar.list.rowViews[.workspace(quiet)] as? WorkspaceRowView)
        #expect(!row.audioButton.isHidden && row.audioButton.alphaValue > 0, "a row with sound shows no speaker")
        #expect(row.audioButton.frame.width > 0 && row.bounds.contains(row.audioButton.frame))
        #expect(silent.audioButton.isHidden, "a silent row shows a speaker")
        row.audioButton.performClick(nil)
        #expect(sent == [.toggleWorkspaceAudio(loud)], "\(sent)")
    }

    // MARK: Palette, CLI and MCP

    /// Mute Tab, Unmute Tab and Mute Other Tabs list in the palette and are CLI verbs and MCP
    /// tools; the toggle the strip's speaker runs is a CLI verb too; the workspace toggle the
    /// row's speaker runs is in the palette, the workspace menu, the CLI and MCP.
    @Test(arguments: [("tab.muteAudio", "tab mute"), ("tab.unmuteAudio", "tab unmute"), ("tab.muteOtherAudio", "tab mute-others"),
                      ("toggleTabAudioMute", "tab mute-unmute"), ("workspace.toggleAudioMute", "workspace mute-unmute")])
    func theMuteActionsAreEverywhere(_ id: String, _ verb: String) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == id }, "no action \(id)")
        #expect(descriptor.cliName == verb)
        #expect(descriptor.surfacePlan.cli?.isOffered == true, "\(id) is no CLI verb")
        #expect(descriptor.surfacePlan.mcp?.isOffered == true, "\(id) is no MCP tool")
        if id != "toggleTabAudioMute" { #expect(descriptor.isPaletteVisible, "\(id) is not in the palette") }
    }

    /// Mute Other Tabs and Mute/Unmute Workspace Tabs each have a menu position no other
    /// action's row shares, so their order in the tab and workspace menus is fixed.
    @Test(arguments: ["workspace.toggleAudioMute"])
    func theMuteRowsHaveTheirOwnMenuPosition(_ id: String) throws {
        let own = try #require(ActionSurfaceCatalog.placements[ActionID(stringLiteral: id)], "\(id) has no menu row")
        for row in own {
            let shared = ActionSurfaceCatalog.placements.filter { key, rows in
                key.rawValue != id && rows.contains { $0.context == row.context && $0.group == row.group && $0.rank == row.rank }
            }.map(\.key.rawValue)
            #expect(shared.isEmpty, "\(id) shares rank \(row.rank) with \(shared)")
        }
    }
}
