import AppKit
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextLayout

/// Posts `name` from a background thread and returns when the post returned.
private func postOffMain(_ name: Notification.Name, object: AnyObject?, on center: NotificationCenter = .default) async {
    let post = OffMainPost(name: name, object: object, center: center)
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        Thread.detachNewThread {
            post.send()
            done.resume()
        }
    }
}

/// One post handed to a background thread (`Thread.detachNewThread`, never
/// main); the object is only passed through.
private nonisolated final class OffMainPost: @unchecked Sendable {
    let name: Notification.Name
    let object: AnyObject?
    let center: NotificationCenter
    init(name: Notification.Name, object: AnyObject?, center: NotificationCenter) {
        self.name = name
        self.object = object
        self.center = center
    }
    func send() { center.post(name: name, object: object) }
}

/// Waits on main (bounded) until `done` holds.
@MainActor
private func waitOnMain(_ done: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !done(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// AppKit and WebKit post notifications off the main thread too. A selector
/// observer whose target is main-actor isolated trapped the whole process
/// there (signal 5, Swift's isolation check; #18771). The observer must
/// survive an off-main post and do its work on main
/// (plans/cmux-next/crash-elimination.md, P1b).
@MainActor @Suite(.serialized)
struct LayoutOffMainNotificationTests {
    final class Pointer { var location: NSPoint? }

    /// A key change of the layout's window posted off main recomputes the
    /// divider hover on main.
    @Test func aKeyChangeOffMainRefreshesTheDividerHoverOnMain() async throws {
        let pointer = Pointer()
        let columns = ["a", "b", "c"].map { id in
            LayoutColumn(id: ColumnID("c\(id)"), width: 0.5, root: .leaf(PaneID(id)))
        }
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .columns(columns))],
                                activeScreenID: "s", focusedPane: "a")
        model.followsDesignMetrics = false
        let view = LayoutRootView(model: model, contentProvider: OffMainStubProvider.shared)
        view.context.reduceMotionOverride = true
        view.context.hoverPointer = { (_: NSWindow) -> NSPoint? in pointer.location }
        view.context.hoverReachesWindow = { (_: NSWindow) -> Bool in true }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let screen = try #require(view.screenViews["s"])
        let edge = try #require(screen.subviews.compactMap { $0 as? DividerHandleView }
            .filter { if case .columnEdge = $0.kind { !$0.isHidden } else { false } }
            .min { $0.frame.minX < $1.frame.minX })
        // The pointer rests on the edge; nothing recomputed the hover yet.
        pointer.location = screen.convert(NSPoint(x: edge.frame.midX, y: edge.frame.midY), to: nil)
        #expect(!edge.isHovered)

        await postOffMain(NSWindow.didBecomeKeyNotification, object: window)
        await waitOnMain { edge.isHovered }
        #expect(edge.isHovered)
    }
}

private final class OffMainStubProvider: LayoutPaneContentProvider {
    static let shared = OffMainStubProvider()
    func makeContentView(for pane: PaneID) -> NSView { NSView() }
}
