import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// A pane whose ground a view above paints (`PaneGroundOwning`: a floating pane with a see-through background). While
/// the owner paints the ground, each view inside that paints one (the content area, a terminal's host) paints none and
/// gives the owner the ground that it would paint, so the text stays solid over one see-through ground. When the owner
/// stops, each view paints its own ground again in the same turn. Before this, the views inside painted an opaque
/// ground over the owner's, and the see-through look showed no change.
@MainActor @Suite(.serialized, .closesItsWindows) struct FloatingPaneGroundTests {
    /// A view above the pane's content that paints its ground or does not, and counts each ground that a view
    /// inside gives it.
    final class Owner: NSView, PaneGroundOwning {
        var ownsContentGround = true {
            didSet { if ownsContentGround != oldValue { tellPaneGroundFollowers() } }
        }
        var changes = 0
        func contentGroundDidChange() { changes += 1 }
    }

    /// The ground that `view` reports for its pane, if it reports one.
    private static func reported(by view: NSView) -> CGColor? { (view as? any PaneGroundReporting)?.paneGround }

    @Test func theContentAreaPaintsNoGroundUnderAnOwner() throws {
        let owner = Owner(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let area = PaneContentAreaView(frame: owner.bounds)
        owner.addSubview(area)
        let ground = CGColor(gray: 0.25, alpha: 1)

        area.waitingGround = ground
        #expect(area.layer?.backgroundColor == nil, "the area paints its ground over the owner's")
        #expect(area.groundColor == ground, "the area does not give the ground that it would paint")

        owner.ownsContentGround = false
        #expect(area.layer?.backgroundColor == ground, "the area paints no ground after the owner stopped")
        #expect(area.groundColor == ground)

        owner.ownsContentGround = true
        #expect(area.layer?.backgroundColor == nil, "the area paints its ground again over the owner's")
        #expect(area.groundColor == ground)
    }

    @Test func theContentAreaKeepsItsRestingGroundRuleUnderAnOwner() throws {
        let owner = Owner(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let area = PaneContentAreaView(frame: owner.bounds)
        owner.addSubview(area)
        let resting = CGColor(gray: 0.5, alpha: 1)

        area.restingGround = resting
        #expect(area.layer?.backgroundColor == nil, "the area paints its resting ground over the owner's")
        #expect(area.groundColor == resting)

        // A pane that paints no resting ground has none to give.
        area.paintsRestingGround = false
        #expect(area.layer?.backgroundColor == nil)
        #expect(area.groundColor == nil)
    }

    @Test func anAreaWithNoOwnerAbovePaintsItsGround() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let area = PaneContentAreaView(frame: root.bounds)
        root.addSubview(area)
        let ground = CGColor(gray: 0.25, alpha: 1)

        area.waitingGround = ground
        #expect(area.layer?.backgroundColor == ground)
        #expect(area.groundColor == ground)
    }

    /// An area that was under an owner and comes into a window with no owner above it paints its own ground again
    /// (`viewDidMoveToWindow`). No view tells the area that its owner is gone, so without that paint the area keeps
    /// no ground: a see-through hole in a tiled pane.
    @Test func anAreaThatLeftItsOwnerPaintsItsGroundInAWindow() throws {
        _ = NSApplication.shared
        let owner = Owner(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let area = PaneContentAreaView(frame: owner.bounds)
        owner.addSubview(area)
        let ground = CGColor(gray: 0.25, alpha: 1)
        area.waitingGround = ground
        // With a ground here, "paints its own again" below would hold by the setup alone.
        try #require(area.layer?.backgroundColor == nil, "the area paints a ground under the owner: this proves nothing")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        root.addSubview(area)
        #expect(area.layer?.backgroundColor == ground, "the area that left its owner paints no ground in the window")
        #expect(area.groundColor == ground)
    }

    @Test func aTerminalHostPaintsNoGroundUnderAnOwnerAndGivesItsOwn() throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let io = GroundScriptedIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 360), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { io.finish(); window.close() }
        let owner = Owner(frame: window.contentLayoutRect)
        owner.ownsContentGround = false
        window.contentView = owner
        let host = session.view
        host.frame = owner.bounds
        owner.addSubview(host)
        host.layoutSubtreeIfNeeded()
        // The ground of a terminal with no owner above: what the window's backdrop gives it. With no ground here,
        // "paints none under the owner" and "paints its own again" below would hold by the setup alone.
        let alone = host.layer?.backgroundColor
        try #require(alone != nil, "the host paints no ground with no owner: the test proves nothing")
        #expect(Self.reported(by: host) == nil, "a host that paints its own ground reports one")
        #expect(owner.changes == 0)

        owner.ownsContentGround = true
        #expect(host.layer?.backgroundColor == nil, "the host paints its ground over the owner's")
        #expect(Self.reported(by: host) == TerminalHostView.opaqueGround(nil),
                "the host does not give the owner the terminal's ground")
        #expect(owner.changes == 1, "the owner heard \(owner.changes) grounds for 1 change")

        owner.ownsContentGround = false
        #expect(host.layer?.backgroundColor == alone, "the host does not paint its own ground again")
        #expect(Self.reported(by: host) == nil)
        #expect(owner.changes == 1, "a host that takes its ground back tells the owner nothing")
    }
}

/// A terminal IO that sends no event: the host under test needs a session, not a program.
private nonisolated final class GroundScriptedIO: TerminalIO {
    let events: AsyncStream<TerminalIOEvent>
    var answersTerminalQueries: Bool { false }
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    func finish() { continuation.finish() }
    func write(_ data: Data) async {}
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}
}
