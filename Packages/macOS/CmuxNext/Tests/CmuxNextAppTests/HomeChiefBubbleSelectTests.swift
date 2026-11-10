import AppKit
@testable import CmuxHomeCore
@testable import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import Foundation
@testable import MessagesLabHome
import CmuxNextTestSupport
import Testing

/// The Chief chat's bubbles select with the mouse through the app's own transcript view
/// (https://github.com/manaflow-ai/cmux/issues/38145): a click-drag selects the words it passed,
/// a double-click the word under the pointer, and a triple-click that bubble's whole text, never a
/// neighbour's. `HomeNativeTranscriptView` in an on-screen window, every press routed as AppKit
/// routes it: the window's views hit-test the down, and the drags and release go to the same view,
/// so a view cmux lays over the transcript that took the press shows here as it does in the app.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeChiefBubbleSelectTests {
    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    private struct Rig {
        let store: HomeStore
        let window: NSWindow
        let view: HomeNativeTranscriptView
        func close() {
            view.stop()
            window.closeAfterTest()
            store.stop()
        }
    }

    private func rig() async throws -> Rig {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        var options = MockHomeSource.Options.immediate
        options.chiefHistory = 12
        options.replyDelay = .seconds(3_600)
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        await until { store.me != nil && store.isOnline }
        let me = try #require(store.me?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
        window.contentView = container
        window.orderFrontRegardless()
        let view = HomeNativeTranscriptView(store: store, conversation: Self.conversation, me: me)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        await until { !store.transcript(for: Self.conversation).isEmpty }
        for _ in 0..<2_000 { await Task.yield() }
        await until { view.transcript.isIdle }
        view.transcript.projection.refresh()
        container.layoutSubtreeIfNeeded()
        view.transcript.controller.demo?.collection.layoutIfNeeded()
        CATransaction.flush()
        return Rig(store: store, window: window, view: view)
    }

    /// The widest shown text bubble (window coordinates, y up) and its text.
    private func bubble(_ rig: Rig) throws -> (frame: CGRect, text: String) {
        let rows = rig.view.transcript.debugRowFrames().filter { $0.kind == "text" && $0.frame.width > 160 && $0.frame.minY > 120 }
        let row = try #require(rows.max { $0.frame.width < $1.frame.width }, "no wide text bubble shows")
        let probe = CGPoint(x: row.frame.midX, y: row.frame.midY)
        let local = rig.view.transcript.controller.host.convert(probe, from: nil)
        let demo = try #require(rig.view.transcript.controller.demo)
        let hit = try #require(demo.hit(local), "no bubble under \(probe)")
        let spec = try #require(demo.model.rows.first { $0.spec.key == hit.key }?.spec)
        // What selection and copy read: the row's display string (markdown without its markers).
        let geometry = try #require(TranscriptSelection.geometry(spec))
        return (row.frame, geometry.substring(NSRange(location: 0, length: geometry.length)))
    }

    /// A point on the bubble's first line, `dx` points into its text (window coordinates, y up).
    private func firstLine(_ frame: CGRect, dx: CGFloat) -> CGPoint {
        CGPoint(x: frame.minX + Fixture.bubblePadX + dx, y: frame.maxY - Fixture.bubblePadY - Fixture.lineHeight / 2)
    }

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
            target = (window.contentView?.superview ?? window.contentView)?.hitTest(p)
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

    @Test func aDragOverAChiefBubbleSelectsTheWordsItPassed() async throws {
        let rig = try await rig()
        defer { rig.close() }
        let (frame, text) = try bubble(rig)
        let start = firstLine(frame, dx: 1)
        let gesture = Gesture(rig.window)
        gesture.down(start)
        let end = min(frame.width - 2 * Fixture.bubblePadX - 4, 140)
        for dx in stride(from: 4.0, through: end, by: 4) { gesture.drag(CGPoint(x: start.x + dx, y: start.y)) }
        gesture.up(CGPoint(x: start.x + end, y: start.y))
        let selected = rig.view.transcript.controller.selection.selectedText
        #expect(!selected.isEmpty, "the drag selected nothing; the press went to \(String(describing: gesture.target))")
        #expect(text.hasPrefix(selected), "selected \(selected.debugDescription) of \(text.debugDescription)")
    }

    @Test func aDoubleClickSelectsOneWord() async throws {
        let rig = try await rig()
        defer { rig.close() }
        let (frame, text) = try bubble(rig)
        Gesture(rig.window).click(firstLine(frame, dx: 3), clicks: 2)
        let selected = rig.view.transcript.controller.selection.selectedText
        #expect(!selected.isEmpty && !selected.contains(" ") && text.contains(selected), "selected \(selected.debugDescription)")
    }

    @Test func aTripleClickSelectsTheWholeBubbleAndOnlyIt() async throws {
        let rig = try await rig()
        defer { rig.close() }
        let (frame, text) = try bubble(rig)
        Gesture(rig.window).click(firstLine(frame, dx: 20), clicks: 3)
        #expect(rig.view.transcript.controller.selection.selectedText == text)
    }
}
