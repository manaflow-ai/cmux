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
/// (`HomeNativeTranscriptView`) in an on-screen window, with the app's toast host.
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

    /// The shown toasts' frames in `window`'s coordinates (they live in its overlay panel).
    private func toastFrames(in window: NSWindow) -> [NSRect] {
        func walk(_ view: NSView) -> [CmuxToastView] {
            (view as? CmuxToastView).map { [$0] } ?? view.subviews.flatMap(walk)
        }
        let views = WindowOverlayHost.host(for: window).panel.contentView.map(walk) ?? []
        // The overlay panel's coordinates are the window's own (WindowOverlayHost.layout).
        return views.map { $0.convert($0.bounds, to: nil) }
    }

    /// Every drawn row clear of every toast; returns the newest row's bottom (window y, up).
    @discardableResult
    private func expectClear(_ window: NSWindow, _ view: HomeNativeTranscriptView, _ step: String,
                             sourceLocation: SourceLocation = #_sourceLocation) throws -> CGFloat {
        let rows = view.transcript.debugRowFrames()
        let toasts = toastFrames(in: window)
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
        window.isReleasedWhenClosed = false
        defer {
            // The window and the overlay panel its toast host keeps (`.closesItsWindows`).
            let panel = WindowOverlayHost.existingHost(for: window)?.panel
            window.closeAfterTest()
            panel?.close()
        }
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
        let rest = try expectClear(window, view, "no toast")

        let center = CmuxToastCenter(host: CmuxToastOverlayHost())
        let long = String(repeating: "Connection to the machine timed out while it updated. ", count: 4)
        let handle = center.show(CmuxToast(id: "machine-update", message: "huge-blue is still on its previous version",
                                           detail: long, action: .details("Details"), duration: CmuxToast.untilClosed),
                                 in: window)
        defer { handle.dismiss() }
        await settle()
        await pass(window, view)
        #expect(toastFrames(in: window).count == 1, "the toast shows")
        let lifted = try expectClear(window, view, "toast shown")
        #expect(lifted > rest + 8, "the newest message stayed where the toast is (\(lifted) vs \(rest))")

        // Details grow the toast upward: the transcript keeps clear of its new height.
        #expect(center.runAction(id: "machine-update", in: window))
        await settle()
        await pass(window, view)
        let higher = try expectClear(window, view, "details shown")
        #expect(higher > lifted + 8, "the details covered the newest message (\(higher) vs \(lifted))")

        // The toast gone (its fade over), the newest message rests where it was.
        handle.dismiss()
        for _ in 0..<150 where !toastFrames(in: window).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(toastFrames(in: window).isEmpty, "the toast never finished fading")
        await settle()
        await pass(window, view)
        let back = try expectClear(window, view, "toast gone")
        #expect(abs(back - rest) < 1, "the newest message did not come back to rest (\(back) vs \(rest))")
    }
}
