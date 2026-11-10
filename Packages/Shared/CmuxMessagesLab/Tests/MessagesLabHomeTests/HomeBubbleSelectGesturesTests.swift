import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Selecting a Chief chat bubble's text with the mouse (https://github.com/manaflow-ai/cmux/issues/38145):
/// a click-drag over a bubble selects the words it passed, a double-click selects the word under
/// the pointer, and a triple-click selects that bubble's whole text and nothing of its neighbours.
///
/// The real Home view over the mock owner in an offscreen window (`HomeChatRig`). Every press goes
/// the way AppKit sends it: the window's view tree hit-tests the press, that view gets the down,
/// and the drags and the release go to the same view. A press that lands on any other view than the
/// transcript's (an overlay, the pane host) is exercised exactly as in the app.
@MainActor @Suite(.serialized) struct HomeBubbleSelectGesturesTests {
    static let first = "\(HomeChatRig.tag) Alpha bravo charlie delta echo foxtrot"
    static let second = "\(HomeChatRig.tag) Golf hotel india juliet kilo lima"
    static let third = "\(HomeChatRig.tag) Mike november oscar papa quebec romeo"

    private func rig() async throws -> HomeChatRig {
        let rig = try await HomeChatRig(history: 4)
        for (n, text) in [Self.first, Self.second, Self.third].enumerated() {
            #expect(await rig.post(text, key: IdempotencyKey("select-\(n)")))
        }
        rig.frame()
        rig.frame()
        return rig
    }

    /// The press point on line one of the bubble showing `text`, `dx` points into its text, in window coordinates.
    private func point(in rig: HomeChatRig, _ text: String, dx: CGFloat) throws -> CGPoint {
        let hit = try #require(rig.view.debugBubble(text: text), "no bubble shows \(text)")
        let local = CGPoint(x: hit.body.minX + Fixture.bubblePadX + dx, y: hit.body.minY + Fixture.bubblePadY + Fixture.lineHeight / 2)
        return rig.view.controller.host.convert(local, to: nil)
    }

    /// Sends one mouse gesture as AppKit routes it: down to the view the window hit-tests, then
    /// every drag and the release to that same view.
    private final class Gesture {
        let window: NSWindow
        var target: NSView?
        init(_ window: NSWindow) { self.window = window }

        func event(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                               pressure: type == .leftMouseUp ? 0 : 1)!
        }

        func down(_ p: CGPoint, clicks: Int = 1) {
            let frame = window.contentView?.superview ?? window.contentView
            target = frame?.hitTest(p)
            target?.mouseDown(with: event(.leftMouseDown, p, clicks: clicks))
        }
        func drag(_ p: CGPoint) { target?.mouseDragged(with: event(.leftMouseDragged, p, clicks: 1)) }
        func up(_ p: CGPoint, clicks: Int = 1) { target?.mouseUp(with: event(.leftMouseUp, p, clicks: clicks)) }
        func click(_ p: CGPoint, clicks: Int) {
            for n in 1...clicks {
                down(p, clicks: n)
                up(p, clicks: n)
            }
        }
    }

    @Test func aDragOverABubbleSelectsTheWordsItPassed() async throws {
        let rig = try await rig()
        defer { rig.stop() }
        let start = try point(in: rig, Self.second, dx: 1)
        let gesture = Gesture(rig.window)
        gesture.down(start)
        for dx in stride(from: 4.0, through: 140, by: 4) { gesture.drag(CGPoint(x: start.x + dx, y: start.y)) }
        gesture.up(CGPoint(x: start.x + 140, y: start.y))
        let selected = rig.view.controller.selection.selectedText
        #expect(!selected.isEmpty, "the drag selected nothing; the press went to \(String(describing: gesture.target))")
        #expect(Self.second.hasPrefix(selected), "selected \(selected.debugDescription)")
    }

    @Test func aDoubleClickSelectsTheWordUnderThePointer() async throws {
        let rig = try await rig()
        defer { rig.stop() }
        // Into "Golf" (after the tag and its space).
        let p = try point(in: rig, Self.second, dx: 24)
        Gesture(rig.window).click(p, clicks: 2)
        #expect(rig.view.controller.selection.selectedText == "Golf")
    }

    @Test func aTripleClickSelectsTheWholeBubbleAndOnlyIt() async throws {
        let rig = try await rig()
        defer { rig.stop() }
        let p = try point(in: rig, Self.second, dx: 60)
        Gesture(rig.window).click(p, clicks: 3)
        #expect(rig.view.controller.selection.selectedText == Self.second)
    }

    @Test func aClickAfterATripleClickLetsTheBubbleGo() async throws {
        let rig = try await rig()
        defer { rig.stop() }
        let p = try point(in: rig, Self.first, dx: 60)
        Gesture(rig.window).click(p, clicks: 3)
        #expect(rig.view.controller.selection.selectedText == Self.first)
        // A single click elsewhere in the bubble lets the selection go, as in Messages.
        let gesture = Gesture(rig.window)
        gesture.click(p, clicks: 1)
        #expect(rig.view.controller.selection.isEmpty)
    }
}
