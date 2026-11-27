import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-11-22T00:23Z, on a row's trailing ⚠ "2/9" and blue dot: "this is kinda odd why is there a yellow and why
/// does it look like that". Leo 2026-11-22T21:56Z, on the same ⚠ still drawn: "i literally said to remove this bullshit
/// over 24 hours ago." The usage warning triangle is gone: a runaway acpmux chat (its summary's `usageWarnings`: no
/// autocompact cap, a huge context, a storm of subagents) draws nothing on its sidebar row, at rest or hovered, pinned
/// or not, and its row's hover card and accessibility label say nothing of it (a mark with no action, cmuxterm-hq
/// docs/handbook/ui-text-says-only-what-you-can-act-on.md).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarUsageWarningTests {
    static let warnings = [
        "No autocompact cap: context is 412k and only compacts at the model's limit",
        "90 subagents started in the last hour, above 40",
    ]

    /// acpmux's summary of a working chat that breaks `warnings`.
    static func summary(_ session: String, warnings: [String]) -> [String: Any] {
        ["sessionId": session, "name": session, "lane": ["state": "working"],
         "usageWarnings": warnings.map { ["rule": "r", "value": 1, "limit": 0, "text": $0] }]
    }

    /// The "working" row the sidebar maps from `fixture`, its chat warned by acpmux or not.
    static func workingRow(_ fixture: SidebarLaneStatusTests.Fixture, warned: Bool) throws -> SidebarWorkspace {
        fixture.lanes.lanes["s-working"] = try #require(AgentActivityLane.of(summary: summary("s-working", warnings: warned ? warnings : [])))
        return try #require(fixture.sections().flatMap(\.workspaces).first { $0.title == "working" })
    }

    /// A warned chat's row maps to exactly the row of the same chat unwarned, with the lane state merge on and off.
    @Test func acpmuxWarningsReachNoRow() throws {
        let fixture = try SidebarLaneStatusTests.Fixture()
        for on in [true, false] {
            try SidebarLaneStatusTests.withLaneStatus(on) {
                let calm = try Self.workingRow(fixture, warned: false)
                let warned = try Self.workingRow(fixture, warned: true)
                #expect(warned == calm, "laneStatus \(on): acpmux's usage warnings changed the row")
            }
        }
    }

    /// What `ws`'s row draws (every visible view, by class and frame) and says (its accessibility label and hover card
    /// facts), at rest or hovered, pinned or not.
    static func drawn(_ ws: SidebarWorkspace, pinned: Bool, hovered: Bool) throws -> (views: [String], label: String?, facts: [String]) {
        Motion.reduceMotionOverride = true // marks clear at once instead of fading out
        defer { Motion.reduceMotionOverride = nil }
        _ = NSApplication.shared
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [.workspace(ws)]),
        ])
        model.workspacePin = (isPinned: { _ in pinned }, toggle: { _ in })
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        sidebar.list.contextMenuProvider = { _ in NSMenu() }
        window.orderFrontRegardless()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        let row = try #require(sidebar.list.rowViews[.workspace(ws.id)] as? WorkspaceRowView)
        row.wire(ws.id, in: sidebar.list)
        row.isHovered = hovered
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        if hovered {
            let controls = [row.closeButton, row.moreButton, row.pinSlot.made].compactMap(\.self).filter { !$0.isHidden && $0.alphaValue > 0 }
            #expect(!controls.isEmpty, "pinned \(pinned): no hover control on the hovered row")
        }
        var views: [String] = []
        func walk(_ view: NSView, depth: Int) {
            for sub in view.subviews where !sub.isHidden && sub.frame.width > 0
                && SidebarTrailingColumnTests.drawnAlpha(sub, below: row) > 0.01 {
                views.append("\(depth) \(type(of: sub)) \(sub.frame)")
                walk(sub, depth: depth + 1)
            }
        }
        walk(row, depth: 0)
        let facts = WorkspaceHoverCardOptions.Layout.allCases.flatMap { layout in
            var options = WorkspaceHoverCardOptions()
            options.layout = layout
            return WorkspaceHoverCardContent.make(ws, machine: nil, now: Date(timeIntervalSince1970: 0), options: options, timeline: [])
                .facts.map { "\(layout) \($0.kind) \($0.text)" }
        }
        return (views, row.accessibilityLabel(), facts)
    }

    /// No row ever draws the usage warning: a warned chat's row draws, says and shows on hover the same as the same row
    /// unwarned, at rest and hovered, pinned and not; no view, label or hover card line carries a warning's text.
    @Test(arguments: [false, true], [false, true])
    func aWarnedRowDrawsNoTriangle(_ pinned: Bool, _ hovered: Bool) throws {
        let fixture = try SidebarLaneStatusTests.Fixture()
        let calm = try Self.drawn(Self.workingRow(fixture, warned: false), pinned: pinned, hovered: hovered)
        let warned = try Self.drawn(Self.workingRow(fixture, warned: true), pinned: pinned, hovered: hovered)
        let state = "pinned \(pinned), hovered \(hovered)"
        #expect(warned.views == calm.views, "\(state): the warned row draws \(warned.views), the calm one \(calm.views)")
        #expect(warned.label == calm.label, "\(state): the warned row's label \(warned.label ?? "nil")")
        #expect(warned.facts == calm.facts, "\(state): the warned row's hover card \(warned.facts)")
        let said = [warned.label ?? ""] + warned.facts
        for warning in Self.warnings {
            #expect(!said.contains { $0.contains(warning) }, "\(state): the row still says \(warning)")
        }
        #expect(!warned.facts.contains { $0.contains("usageWarning") }, "\(state): a usage warning line in the hover card")
    }
}
