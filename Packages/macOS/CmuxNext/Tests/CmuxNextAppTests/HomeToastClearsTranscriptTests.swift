import AppKit
@testable import CmuxHomeCore
@testable import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import Foundation
@testable import MessagesLabHome
import CmuxNextTestSupport
import Testing

/// A toast never covers the chat (Leo: "why is this still happening yo", a machine-update toast
/// drawn over his own message in the Chief chat). Toasts sit bottom-center over the window, clear
/// of the message box; the transcript keeps its newest rows above them, through Details growing
/// the toast, and rests where it was once they go. Through the app's transcript view
/// (`HomeNativeTranscriptView`) in an on-screen window; the toasts are the rects the app's web
/// toast host reports to the window's reserving views (`CmuxToastReserving.toastsSettled`), placed
/// as it places them: bottom-center, on the floor clear of the message box.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeToastClearsTranscriptTests {
    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    private func settle() async {
        for _ in 0..<2_000 { await Task.yield() }
    }

    private func pass(_ window: NSWindow, _ view: HomeNativeTranscriptView) async {
        // A send's field and rows finish their motion first: a reading mid-motion is off by a point.
        await until { view.transcript.isIdle }
        view.transcript.projection.refresh()
        window.contentView?.layoutSubtreeIfNeeded()
        view.transcript.controller.demo?.collection.layoutIfNeeded()
        CATransaction.flush()
    }

    /// What the toast host tells `window`'s reserving views: the toasts now rest in `rect` (nil: none
    /// shows), at once. Returns the rect, as the shown toasts' frames.
    @discardableResult
    private func report(_ window: NSWindow, toasts rect: NSRect?) -> [NSRect] {
        for view in CmuxToastAvoidance.reservingViews(in: window) { view.toastsSettled(in: rect, duration: 0) }
        return rect.map { [$0] } ?? []
    }

    /// A toast of `size` where the host draws it: bottom-center of the content, on the floor clear
    /// of the window's avoided views.
    private func toastRect(_ size: NSSize, in window: NSWindow) throws -> NSRect {
        let bounds = try #require(window.contentView).bounds
        let floor = CmuxToastAvoidance.floor(width: size.width, in: bounds, window: window)
        return NSRect(x: bounds.midX - size.width / 2, y: floor, width: size.width, height: size.height)
    }

    /// Every drawn row clear of every toast; returns the newest row's bottom (window y, up).
    @discardableResult
    private func expectClear(_ window: NSWindow, _ view: HomeNativeTranscriptView, _ step: String, toasts: [NSRect],
                             sourceLocation: SourceLocation = #_sourceLocation) throws -> CGFloat {
        // A message part gives its drawn balloon; any other row (a receipt, a label) gives its cell's whole
        // content, which keeps RowDraw.margin above and below the row for drawing room. Only the row draws.
        let rows = view.transcript.debugRowFrames().map { row -> (key: String, balloon: CGRect) in
            (row.key, row.kind == "text" || row.kind == "part" ? row.balloon : row.balloon.insetBy(dx: 0, dy: RowDraw.margin))
        }
        print("toast-clear \(step): toasts=\(toasts) newest=\(rows.min { $0.balloon.minY < $1.balloon.minY }.map { "\($0.key) \($0.balloon)" } ?? "none")")
        #expect(!rows.isEmpty, "\(step): no rows drawn", sourceLocation: sourceLocation)
        for toast in toasts {
            for row in rows where row.balloon.intersects(toast.insetBy(dx: 0, dy: 1)) {
                Issue.record("\(step): toast \(toast) covers row \(row.key) at \(row.balloon)", sourceLocation: sourceLocation)
            }
        }
        return try #require(rows.map(\.balloon.minY).min(), sourceLocation: sourceLocation)
    }

    @Test func aToastNeverCoversTheNewestMessages() async throws {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        var options = MockHomeSource.Options.immediate
        options.chiefHistory = 60
        // No reply comes: the message sent below stays the newest row, still on its way (Leo's queued prompt).
        options.replyDelay = .seconds(3_600)
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        defer { store.stop() }
        await until { store.me != nil && store.isOnline }
        let me = try #require(store.me?.id)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
        window.contentView = container
        window.orderFrontRegardless()

        let view = HomeNativeTranscriptView(store: store, conversation: Self.conversation, me: me)
        defer { view.stop() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        // A borderless window keeps its size on any screen (a titled one is fitted to a small one).
        #expect(window.contentView?.bounds.size == NSSize(width: 900, height: 800), "the window was resized")
        await until { !store.transcript(for: Self.conversation).isEmpty }
        await settle()
        await pass(window, view)
        // A message of mine, just sent, waits under the Chief's history as the newest row.
        view.transcript.setDraft("what's going on here")
        #expect(view.transcript.sendDraft() == nil, "the draft was not sent")
        await settle()
        await pass(window, view)
        let rest = try expectClear(window, view, "no toast", toasts: [])
        #expect(CmuxToastAvoidance.reservingViews(in: window).contains { $0 === view }, "the transcript reserves no room")

        // A machine-update toast shows (a two-line message with Details).
        let shown = try report(window, toasts: toastRect(NSSize(width: 420, height: 64), in: window))
        await settle()
        await pass(window, view)
        let lifted = try expectClear(window, view, "toast shown", toasts: shown)
        #expect(lifted > rest + 8, "the newest message stayed where the toast is (\(lifted) vs \(rest))")

        // Details grow the toast upward: the transcript keeps clear of its new height.
        let grown = try report(window, toasts: toastRect(NSSize(width: 480, height: 200), in: window))
        await settle()
        await pass(window, view)
        let higher = try expectClear(window, view, "details shown", toasts: grown)
        #expect(higher > lifted + 8, "the details covered the newest message (\(higher) vs \(lifted))")

        // The toast gone, the newest message rests where it was.
        report(window, toasts: nil)
        await settle()
        await pass(window, view)
        let back = try expectClear(window, view, "toast gone", toasts: [])
        #expect(abs(back - rest) < 1, "the newest message did not come back to rest (\(back) vs \(rest))")
    }
}
