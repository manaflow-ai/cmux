import AppKit
import CmuxNextCompat
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import ObjectiveC
import Testing

/// 2026-10-28 (cmux21 cmux-2026-10-28-114922.ips, handoff/cef-parent-tracker-crash.md): closing a hidden Settings tab
/// aborted the app. InternalPageTabStore.forget let go of the tab's InternalPageView with the page still inside, so
/// AppKit removed the page in `-[NSView dealloc]`; the page lost its hidden ancestor there, and the CEF fork's parent
/// tracker (a probe view in the page) stored a weak reference to the deallocating view. The store now takes the
/// content out of the tab's view in the forget's turn, while every view is alive: nothing leaves a hierarchy in a
/// dealloc.
@MainActor
private final class ProbePage: InternalPageProvider {
    let page: InternalPageID
    let title = "Probe page"
    let symbol = "doc"
    /// The content each key got; the test keeps it, as a provider that keeps its page (Settings) does.
    private(set) var contents: [String: NSView] = [:]

    init(_ page: InternalPageID) { self.page = page }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let probe = TeardownProbe(frame: .zero)
        content.addSubview(probe)
        contents[key] = content
        return content
    }
}

/// Stands for the fork's CmuxParentViewProbe: on each hierarchy and hidden change it checks, as the tracker's weak
/// chain store does, that every ancestor still allows a weak reference (not deallocating).
private final class TeardownProbe: NSView {
    private(set) var sawDeallocatingAncestor = false

    private func check() {
        var view = superview
        while let ancestor = view {
            if !Self.allowsWeakReference(ancestor) { sawDeallocatingAncestor = true }
            view = ancestor.superview
        }
    }

    // crash-allow: NSObject's allowsWeakReference is answered by every object (objc runtime NSObject.mm); a test-only probe.
    private static func allowsWeakReference(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("allowsWeakReference")
        guard object.responds(to: selector), let method = class_getMethodImplementation(type(of: object), selector) else { return true }
        typealias Allows = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Allows.self)(object, selector)
    }

    override func viewDidUnhide() { super.viewDidUnhide(); check() }
    override func viewDidHide() { super.viewDidHide(); check() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); check() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); check() }
}

@MainActor @Suite(.serialized)
struct InternalPageForgetTeardownTests {
    @Test func closingAHiddenPageTabTakesItsContentOutWhileItsViewLives() async throws {
        _ = NSApplication.shared
        let pages = InternalPageTabStore()
        let provider = ProbePage(InternalPageID(rawValue: "test.forget-teardown"))
        pages.register(provider)
        let key = pages.open(provider.page, in: "pane-forget", of: DaemonStore(), window: nil)
        weak var tabView: InternalPageView?
        try autoreleasepool {
            let view = try #require(pages.view(for: key))
            tabView = view
            _ = view.content // built, as a shown tab is
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            container.addSubview(view)
            view.isHidden = true // a background tab
            pages.close(key)
        }
        for _ in 0..<20 { await Task.yield() }
        let content = try #require(provider.contents[key])
        let probe = try #require(content.subviews.first as? TeardownProbe)
        try #require(tabView == nil, "the closed tab's view was not freed: the test cannot see its teardown")
        #expect(content.superview == nil, "the closed tab's content stayed in its view")
        #expect(!probe.sawDeallocatingAncestor, "the page left its hierarchy inside a dealloc (the CmuxParentViewTracker abort)")
    }

    /// The detector: a tab view freed with its content still in it names its page; one that gave its content up does not.
    @Test func aTabViewFreedWithItsContentReportsItsPage() async throws {
        _ = NSApplication.shared
        let reported = Mutex<[String]>([])
        let page = InternalPageID(rawValue: "test.freed-attached")
        do {
            let attached = InternalPageView(key: "a", page: page, content: NSView())
            attached.reportFreedAttached { id in reported.withLock { $0.append("attached:" + id.rawValue) } }
            let detached = InternalPageView(key: "b", page: page, content: NSView())
            detached.reportFreedAttached { id in reported.withLock { $0.append("detached:" + id.rawValue) } }
            detached.detachContent()
        }
        for _ in 0..<20 { await Task.yield() }
        let got = reported.withLock { $0 }
        #expect(got == ["attached:test.freed-attached"], "reported \(got)")
    }
}
