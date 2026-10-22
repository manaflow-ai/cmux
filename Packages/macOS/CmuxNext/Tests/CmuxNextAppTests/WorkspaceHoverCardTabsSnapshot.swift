import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// u9696 gallery: the workspace card of the user's screenshot ("skibidi": an agent, two shells, a
/// page and a chat over three panes) and a 20-tab workspace, drawn offscreen on the card's dark
/// glass color and written to `artifacts/hover-card-tabs/` at the repository root (the fleet step
/// returns them). The card must draw something and list its tabs.
@MainActor @Suite(.serialized) struct WorkspaceHoverCardTabsSnapshot {
    static var outputDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/hover-card-tabs", isDirectory: true)
    }

    static let skibidi = SidebarWorkspace(
        id: WorkspaceID("skibidi"), title: "skibidi", directory: "~", activity: .working,
        tabs: [
            SidebarTab(id: TabID("a"), title: "Claude Code", brand: "claude", state: .working,
                       detail: "claude: Editing Sources/Sidebar/HoverCard.swift", pane: 0),
            SidebarTab(id: TabID("b"), title: "zsh", isUnread: true, detail: "~/fun/cmux", pane: 0),
            SidebarTab(id: TabID("c"), title: "cmux-lawrence", state: .waiting, detail: "ssh: Password for lawrence", pane: 1),
            SidebarTab(id: TabID("d"), title: "Pull requests · manaflow-ai/cmux", kind: .browser, detail: "github.com", pane: 1,
                       flags: [.playing]),
            SidebarTab(id: TabID("e"), title: "Docs", kind: .browser, detail: "developer.apple.com", pane: 1, flags: [.hibernated]),
            SidebarTab(id: TabID("f"), title: "Fix the sidebar drag", kind: .agentChat, brand: "codex", state: .waiting,
                       detail: "Codex", pane: 2),
        ])

    static func render(_ workspace: SidebarWorkspace, name: String) throws -> (WorkspaceHoverCardView, Int) {
        _ = NSApplication.shared
        let card = WorkspaceHoverCardView()
        card.appearance = NSAppearance(named: .darkAqua)
        card.configure(.make(workspace, machine: nil, now: Date()))
        let size = card.fittingSize
        let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        backdrop.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = backdrop
        card.frame = backdrop.bounds
        backdrop.addSubview(card)
        card.applyColors()
        window.layoutIfNeeded()
        backdrop.displayIfNeeded()
        let rep = try #require(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
        window.contentView = nil
        window.close()
        return (card, png.count)
    }

    @Test func theSkibidiCardListsItsTabs() throws {
        let (card, bytes) = try Self.render(Self.skibidi, name: "after-skibidi")
        #expect(bytes > 1000)
        #expect(card.tabLines.count == 6 + 3)
    }

    @Test func aTwentyTabCardCapsItsList() throws {
        let workspace = SidebarWorkspace(id: WorkspaceID("many"), title: "cmux-next perf", directory: "~/fun/cmux", activity: .working,
                                         tabs: WorkspaceHoverCardTabsBench.tabs(7))
        let (card, bytes) = try Self.render(workspace, name: "after-20-tabs")
        #expect(bytes > 1000)
        #expect(card.tabLines.last == Strings.statusMore(20 - WorkspaceHoverCardView.visibleTabLimit))
    }
}
