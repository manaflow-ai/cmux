import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// A tab page's hosting view leaves the window while its node is hidden and comes back in the show
/// turn, with the keyboard and accessibility; the gate's counter attributes the page's body evaluations
/// to the node's state. The SwiftUI side (no body while hidden, one on show, typed state kept) is tested
/// with real pages: TasksHostViewGateTests and VisibilityGatedPagesTests (CmuxNextAppTests).
@MainActor
struct VisibilityGatedHostingViewTests {
    /// A page that draws one solid color.
    final class SolidView: NSView {
        let color: NSColor
        init(_ color: NSColor) {
            self.color = color
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            bounds.fill()
        }
    }

    /// A view that takes the keyboard and is one accessibility element.
    final class FocusView: NSView {
        override var acceptsFirstResponder: Bool { true }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
    }

    @MainActor struct Fixture {
        let window: NSWindow
        let app: VisibilityNode
        let tab: VisibilityNode
        let gate: VisibilityGatedHostingView
        let ledger: ObservationLedger

        /// The app's layout and display pass for the window.
        func pass() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    private static func fixture(_ gate: VisibilityGatedHostingView) -> Fixture {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = gate
        let app = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", own: .visible, parent: app)
        let ledger = ObservationLedger()
        gate.follow(tab, observations: ledger)
        let fixture = Fixture(window: window, app: app, tab: tab, gate: gate, ledger: ledger)
        fixture.pass()
        return fixture
    }

    @Test func theCounterAttributesBodiesToTheNodeAndTheLedger() throws {
        let counter = HostingBodyCounter()
        let gate = VisibilityGatedHostingView(owner: "Probe", counter: counter, hosting: NSView())
        let fixture = Self.fixture(gate)
        defer { fixture.close() }
        _ = fixture.ledger.snapshot(matching: "Hosting.Probe", resetting: true)

        counter.record()
        #expect(gate.bodyEvaluations == (1, 0), "a body while shown: \(gate.bodyEvaluations)")
        fixture.tab.set(.hidden)
        #expect(gate.isGated && gate.hosting.superview == nil, "the hosting view left the window in the hide turn")
        counter.record()
        #expect(gate.bodyEvaluations == (2, 1), "a body while hidden counts as hidden: \(gate.bodyEvaluations)")

        let entry = try #require(fixture.ledger.snapshot(matching: "Hosting.Probe").first)
        #expect(entry.bodyEvaluations == 2 && entry.hiddenBodyEvaluations == 1, "debug.observations: \(entry)")
    }

    @Test func theKeyboardComesBackToTheViewThatHadIt() throws {
        let hosting = NSView()
        let field = FocusView()
        field.frame = NSRect(x: 10, y: 10, width: 100, height: 20)
        hosting.addSubview(field)
        let gate = VisibilityGatedHostingView(owner: "Focus", hosting: hosting)
        let fixture = Self.fixture(gate)
        defer { fixture.close() }
        #expect(fixture.window.makeFirstResponder(field))

        fixture.tab.set(.hidden)
        #expect(fixture.window.firstResponder !== field, "the keyboard left with the hosting view")
        #expect(!Self.accessibilityTree(of: gate).contains { $0 === field }, "a hidden page shows no accessibility element")

        fixture.tab.set(.visible)
        #expect(fixture.window.firstResponder === field, "the keyboard came back in the show turn")
        #expect(Self.accessibilityTree(of: gate).contains { $0 === field }, "its accessibility element came back")
    }

    @Test func theKeyboardStaysWhereThePersonMovedIt() throws {
        let hosting = NSView()
        let field = FocusView()
        hosting.addSubview(field)
        let elsewhere = FocusView()
        let gate = VisibilityGatedHostingView(owner: "Focus", hosting: hosting)
        let fixture = Self.fixture(gate)
        defer { fixture.close() }
        gate.addSubview(elsewhere)
        #expect(fixture.window.makeFirstResponder(field))

        fixture.tab.set(.hidden)
        #expect(fixture.window.makeFirstResponder(elsewhere))
        fixture.tab.set(.visible)
        #expect(fixture.window.firstResponder === elsewhere, "showing the page does not take the keyboard back")
    }

    @Test func anOccludedOrCapturedPageKeepsItsHostingView() {
        let gate = VisibilityGatedHostingView(owner: "Kept", hosting: NSView())
        let fixture = Self.fixture(gate)
        defer { fixture.close() }

        fixture.app.set(.occluded)
        #expect(!gate.isGated, "an occluded window keeps its layout ready (Chrome OCCLUDED)")
        fixture.app.set(.visible)

        fixture.tab.set(.hidden)
        #expect(gate.isGated)
        let capture = fixture.tab.captureVote(reason: "test capture", stayHidden: true)
        #expect(!gate.isGated, "a capture vote reads the live page")
        capture.release()
        #expect(gate.isGated, "the vote released: out again")
    }

    @Test func anOptedOutPageStaysAndCountsItsHiddenBodies() throws {
        let counter = HostingBodyCounter()
        let gate = VisibilityGatedHostingView(owner: "OptOut", policy: .optOut(reason: "test: runs while hidden"),
                                              counter: counter, hosting: NSView())
        let fixture = Self.fixture(gate)
        defer { fixture.close() }

        fixture.tab.set(.hidden)
        #expect(!gate.isGated && gate.hosting.superview === gate)
        counter.record()
        #expect(gate.bodyEvaluations.hidden >= 1, "the opted-out page ran while hidden: \(gate.bodyEvaluations)")
        let entry = try #require(fixture.ledger.snapshot(matching: "Hosting.OptOut").first)
        #expect(entry.hiddenBodyEvaluations >= 1)
    }

    @Test func aWalkFindsTheHostedViewsOfAHiddenPage() {
        let hosting = NSView()
        let scroll = NSScrollView()
        hosting.addSubview(scroll)
        let gate = VisibilityGatedHostingView(owner: "Walk", hosting: hosting)
        let fixture = Self.fixture(gate)
        defer { fixture.close() }

        fixture.tab.set(.hidden)
        #expect(!gate.subviews.contains { $0 === hosting })
        #expect(gate.subviewsIncludingGated.contains { $0 === hosting }, "a scroll position walk still reaches the page")
    }

    @Test func unfollowingBringsTheHostingViewBack() {
        let gate = VisibilityGatedHostingView(owner: "Unfollow", hosting: NSView())
        let fixture = Self.fixture(gate)
        defer { fixture.close() }

        fixture.tab.set(.hidden)
        #expect(gate.isGated)
        gate.unfollow()
        #expect(!gate.isGated && gate.hosting.superview === gate)
        #expect(fixture.tab.subscriberCounts.flips == 0 && fixture.tab.subscriberCounts.exemptions == 0, "no subscription is left")
    }

    @Test func aHideDrawsNothingAndKeepsNoPicture() {
        let gate = VisibilityGatedHostingView(owner: "NoPicture", hosting: SolidView(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)))
        let fixture = Self.fixture(gate)
        defer { fixture.close() }

        fixture.tab.set(.hidden)
        #expect(gate.isGated)
        #expect(gate.subviews.isEmpty, "no picture view stands in for the page: \(gate.subviews)")
        #expect(gate.layer?.contents == nil && (gate.layer?.sublayers ?? []).allSatisfy { $0.contents == nil },
                "the hidden page keeps no bitmap")
    }

    @Test func aSnapshotOfAHiddenPageDrawsItAndLeavesItOut() throws {
        let gate = VisibilityGatedHostingView(owner: "Snapshot", hosting: SolidView(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)))
        let fixture = Self.fixture(gate)
        defer { fixture.close() }

        fixture.tab.set(.hidden)
        let image = try #require(gate.cachedDisplayImage(), "a hidden page draws for a snapshot")
        let center = try #require(Self.pixel(of: image, x: image.width / 2, y: image.height / 2))
        #expect(center.redComponent > 0.8 && center.greenComponent < 0.25 && center.blueComponent < 0.25 && center.alphaComponent > 0.8,
                "the page, not a blank: \(center)")
        #expect(gate.isGated && gate.hosting.superview == nil, "the hosting view left again after the drawing")
    }

    /// One pixel of `image` (top-left origin), in sRGB.
    static func pixel(of image: CGImage, x: Int, y: Int) -> NSColor? {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    /// Every accessibility element under `view`, depth first.
    private static func accessibilityTree(of view: NSView) -> [AnyObject] {
        var found: [AnyObject] = []
        var pending: [Any] = view.accessibilityChildren() ?? []
        while let next = pending.popLast() {
            found.append(next as AnyObject)
            if let view = next as? NSView { pending.append(contentsOf: view.accessibilityChildren() ?? []) }
        }
        return found
    }
}
