import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S3 (`motion.frameOwner.contentPolicy`, default on): the rules the content policy keeps beside
/// PaneGroundCoversPaneTests (the shell never shows inside a pane rect).
/// - The switch is latched when each hold begins: a flip in the middle of a spring leaves that spring on its path.
/// - In a key resize the terminal surface (the producer) stays fixed at the pane edge that does not move, for each side
///   a pane can grow or shrink on, while its host (the container) follows the pane in every frame.
/// - One grid per press: each terminal asks its PTY for its final grid once, in the key's turn, and its surface takes a
///   new size at most once (no surface `setFrameSize` per frame, no reflow per frame).
/// - S3c: a closing pane shows its ground as it was at the close, the same host comes back when a close is taken back,
///   and nothing of it is left in the view tree after the landing.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneContentPolicyTests {
    typealias Rig = PaneGroundCoversPaneTests.Rig

    /// The terminal surface of `pane`, and where it shows in the window.
    static func surface(_ pane: PaneID, in rig: Rig) throws -> TerminalSurfaceView {
        try #require(rig.provider.sessions[pane]?.session.surfaceView, "\(pane) shows no terminal")
    }

    /// Steps the motion to its landing and its release; `frame` runs after each frame's layout pass. The frame count.
    @discardableResult
    static func run(_ rig: Rig, frame: (Int) throws -> Void = { _ in }) rethrows -> Int {
        var frames = 0
        while frames < 240, rig.frame() {
            frames += 1
            try frame(frames)
        }
        rig.commit()
        return frames
    }

    // MARK: Note 1: latched per hold

    /// The switch flipped off in the middle of a key press's spring: that spring finishes on the path it started on (the
    /// hosts follow their panes to the landing), and the next press takes the off path (the host is held whole).
    @Test func aSwitchFlipMidSpringAppliesFromTheNextMotion() throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        rig.root.context.contentPolicyOverride = true
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        var found: [String] = []
        let frames = try Self.run(rig) { frame in
            if frame == 4 { rig.root.context.contentPolicyOverride = false }
            found += rig.misses().map { "frame \(frame): \($0)" }
        }
        #expect(frames > 6, "the press did not spring (\(frames) frames)")
        #expect(found.isEmpty, "a flip at frame 4 changed the spring's path: \(found.prefix(3))")

        // The next press runs with the switch off: the terminal host is held whole (S1), so its ground is short of
        // the growing pane: the path this press started on.
        #expect(PaneResize.press("p2", .left, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        var offMisses = 0
        try Self.run(rig) { _ in offMisses += rig.misses().count }
        #expect(offMisses > 0, "the press after the flip did not take the off path (the host followed its pane)")
    }

    // MARK: Note 2: the surface stays fixed at the pane edge that does not move

    /// One press on each side of each axis. p2 grows to the left (H: its leading edge moves, the surface rides the
    /// trailing edge), p1 grows to the right (L on p1: the trailing edge moves, it rides the leading edge), p2 grows up
    /// (K: its top edge moves, it rides the bottom), p1 grows down (J on p1: its bottom edge moves, it rides the top).
    /// The shrinking pane beside each rides its own edge that stays. The host follows the pane in every frame.
    nonisolated struct Side: Sendable, CustomTestStringConvertible {
        let vertical: Bool
        let pressed: PaneID
        let direction: LayoutDirection
        var testDescription: String { "\(pressed) \(direction)" }
    }

    nonisolated static let sides: [Side] = [
        Side(vertical: false, pressed: "p2", direction: .left), Side(vertical: false, pressed: "p1", direction: .right),
        Side(vertical: true, pressed: "p2", direction: .up), Side(vertical: true, pressed: "p1", direction: .down),
    ]

    @Test(arguments: sides)
    func theSurfaceStaysAtThePaneEdgeThatDoesNotMove(_ side: Side) throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(side.vertical ? PaneGroundCoversPaneTests.stack : PaneGroundCoversPaneTests.pair),
                      focused: side.pressed)
        defer { rig.close() }
        rig.root.context.contentPolicyOverride = true
        var start: [PaneID: CGRect] = [:]
        for pane in ["p1", "p2"] as [PaneID] {
            let host = try #require(rig.root.context.hosts[pane])
            start[pane] = host.convert(host.roundedRect, to: nil)
        }
        #expect(PaneResize.press(side.pressed, side.direction, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        var off: [String] = []
        let frames = try Self.run(rig) { frame in
            for pane in ["p1", "p2"] as [PaneID] {
                let host = try #require(rig.root.context.hosts[pane]), was = try #require(start[pane])
                let area = host.convert(host.roundedRect, to: nil)
                let shown = try Self.surface(pane, in: rig)
                let surface = shown.convert(shown.bounds, to: nil)
                let terminal = try #require(rig.provider.sessions[pane]?.session.view)
                let ground = terminal.convert(terminal.bounds, to: nil)
                // The edge that stays: the one whose window position is where it was before the press.
                let edges: [(String, CGFloat, CGFloat, CGFloat)] = side.vertical
                    ? [("bottom", area.minY, was.minY, surface.minY), ("top", area.maxY, was.maxY, surface.maxY)]
                    : [("leading", area.minX, was.minX, surface.minX), ("trailing", area.maxX, was.maxX, surface.maxX)]
                for (name, now, before, at) in edges where abs(now - before) < 0.5 {
                    // A padded surface sits one padding inside the host: compare it with where it sat at rest.
                    let inset = at - now
                    if abs(inset) > 12 { off.append("frame \(frame): \(pane)'s surface left the \(name) edge that stays (\(at) vs \(now))") }
                }
                if !ground.insetBy(dx: -1, dy: -1).contains(area) {
                    off.append("frame \(frame): \(pane)'s host \(ground) does not follow its pane \(area)")
                }
            }
        }
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(off.isEmpty, "\(off.count) frames off: \(off.prefix(3))")
    }

    // MARK: Note 3: one grid per press

    /// One press with the switch on: each terminal asks its PTY for one grid, the final one, in the key's turn; its
    /// surface takes a new size at most once in the whole press (none per frame), and none at the landing.
    @Test(arguments: [LayoutDirection.left, .right, .up, .down])
    func aKeyPressSizesEachSurfaceOnceAndSendsOneGrid(direction: LayoutDirection) async throws {
        let vertical = direction == .up || direction == .down
        let rig = Rig(PaneGroundCoversPaneTests.column(vertical ? PaneGroundCoversPaneTests.stack : PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        rig.root.context.contentPolicyOverride = true
        let panes: [PaneID] = ["p1", "p2"]
        for pane in panes { _ = try await Self.grids(pane, rig) }
        var sizes: [PaneID: [CGSize]] = [:]
        var last: [PaneID: CGSize] = [:]
        for pane in panes { last[pane] = try Self.surface(pane, in: rig).frame.size }
        func note() throws {
            for pane in panes {
                let size = try Self.surface(pane, in: rig).frame.size
                if size != last[pane] { sizes[pane, default: []].append(size) }
                last[pane] = size
            }
        }
        let reportsBefore = TerminalSurfaceView.gridReports
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        try note()
        let frames = try Self.run(rig) { _ in try note() }
        try note()
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(TerminalSurfaceView.gridReports - reportsBefore <= UInt64(panes.count), "more grid reports than terminals for one press")
        for pane in panes {
            let grids = try await Self.grids(pane, rig)
            let final = try #require(try Self.surface(pane, in: rig).fittedGrid)
            #expect(grids == [final], "\(pane) asked its PTY for \(grids), not its final grid \(final) once")
            #expect((sizes[pane] ?? []).count <= 1, "\(pane)'s surface took \(sizes[pane]?.count ?? 0) sizes in one press: \(sizes[pane] ?? [])")
        }
    }

    /// The grids `pane`'s terminal asked its PTY for since the last call (a focus report after them is the marker).
    static func grids(_ pane: PaneID, _ rig: Rig) async throws -> [TerminalGridSize] {
        let session = try #require(rig.provider.sessions[pane])
        session.session.surfaceView.bridge.takeUnretainedValue().input.focusGained()
        return await session.io.gridsUntilMarker()
    }

    // MARK: Note 5: S3c

    /// A closing pane shows the ground it had at the close (a theme change during the close changes nothing), it shows no
    /// content, and after the landing its host, ring and content are gone from the view tree.
    @Test func aClosingPaneShowsItsGroundReadAtTheCloseAndLeavesNothingBehind() throws {
        let rig = Rig(.columns([LayoutColumn(id: "c0", width: 1.0 / 3, root: .leaf("p1")), LayoutColumn(id: "c1", width: 1.0 / 3, root: .leaf("p2")),
                                LayoutColumn(id: "c2", width: 1.0 / 3, root: .leaf("p3"))]), focused: "p2")
        defer { rig.close() }
        rig.root.context.contentPolicyOverride = true
        let host = try #require(rig.root.context.hosts["p2"])
        let terminal = try #require(rig.provider.sessions["p2"]?.session.view)
        let ground = try #require(terminal.layer?.backgroundColor, "SETUP: the terminal paints no ground")
        let layersBefore = Self.layerCount(rig.root), closedLayers = Self.layerCount(host) + Self.layerCount(host.chrome)
        try #require(closedLayers > 2, "SETUP: the closing pane has \(closedLayers) layers")
        _ = try #require(rig.model.showPaneClose("p2"))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        #expect(!host.isHidden && host.showsClosingGround, "the closing host is not shown with its ground")
        #expect(host.content.isHidden, "the closing pane still shows its content")
        // A repaint of the terminal during the close does not reach the closing ground: it was read at the close.
        terminal.layer?.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        var shownGrounds: [CGColor?] = []
        var widths: [CGFloat] = []
        try Self.run(rig) { _ in
            if host.superview != nil {
                shownGrounds.append(host.clipView.layer?.backgroundColor)
                widths.append(host.frame.width)
            }
        }
        #expect(!widths.isEmpty, "the closing pane did not show on its close spring")
        #expect(zip(widths, widths.dropFirst()).allSatisfy { $0.1 <= $0.0 + 0.5 }, "the closing pane grew: \(widths.prefix(8))")
        #expect(shownGrounds.allSatisfy { $0 == ground }, "the closing ground was not the one read at the close")
        #expect(host.superview == nil && host.chrome.superview == nil, "the closing host or its ring is left in the view tree")
        #expect(rig.root.context.closingHost("p2", of: "s") == nil, "the closing host is still retired after the landing")
        #expect(!Self.contains(rig.root, host) && !Self.contains(rig.root, host.content), "the closed pane's views are left in the window")
        let layersAfter = Self.layerCount(rig.root)
        #expect(layersAfter <= layersBefore - closedLayers,
                "the window has \(layersAfter) layers after the landing; \(layersBefore) before the close less the closed pane's \(closedLayers)")
        #expect(host.layer?.superlayer == nil && host.chrome.layer?.superlayer == nil, "a closed pane's layer is still in a layer tree")
    }

    /// A close taken back before it landed shows the same host again, with its content, from where its closing frame
    /// showed: no new host, no new terminal.
    @Test func aCloseTakenBackShowsTheSameHost() throws {
        let rig = Rig(.columns([LayoutColumn(id: "c0", width: 0.5, root: .leaf("p1")), LayoutColumn(id: "c1", width: 0.5, root: .leaf("p2"))]),
                      focused: "p2")
        defer { rig.close() }
        rig.root.context.contentPolicyOverride = true
        let host = try #require(rig.root.context.hosts["p2"])
        let session = try #require(rig.provider.sessions["p2"]?.session)
        let close = try #require(rig.model.showPaneClose("p2"))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        for _ in 1...5 { _ = rig.frame() }
        let shown = host.frame
        #expect(host.showsClosingGround && shown.width > 1, "SETUP: p2 is not on its close spring (\(shown))")
        rig.model.cancelPaneClose(close)
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        #expect(rig.root.context.hosts["p2"] === host, "the close taken back made a new host")
        #expect(!host.showsClosingGround && !host.content.isHidden, "the host taken back does not show its content")
        #expect(abs(host.frame.width - shown.width) < 24, "the host taken back jumped from \(shown) to \(host.frame)")
        try Self.run(rig)
        #expect(rig.provider.sessions["p2"]?.session === session, "the close taken back made a new terminal")
        #expect(host.superview != nil && !host.isHidden, "the host taken back is not in the layout after the landing")
    }

    /// The layers of `view`'s tree: each view's backing layer, the views under it included.
    static func layerCount(_ view: NSView) -> Int {
        (view.layer == nil ? 0 : 1) + view.subviews.reduce(0) { $0 + layerCount($1) }
    }

    static func contains(_ root: NSView, _ view: NSView) -> Bool { view.isDescendant(of: root) }
}
