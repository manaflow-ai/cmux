import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Observation
import SwiftUI
import Testing

/// A tab page's SwiftUI leaves the window while its node is hidden and comes back in the show turn:
/// no body runs while hidden, one runs on show, and the keyboard and accessibility
/// come back with it.
@MainActor
struct VisibilityGatedHostingViewTests {
    @Observable final class Probe {
        var value = 0
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

    @Test func aHiddenPageRunsNoBodyAndOneOnShow() throws {
        let probe = Probe()
        // The root reads the model, so each change it sees is one root body.
        let gate = VisibilityGatedHostingView(owner: "Probe") { Text(verbatim: "\(probe.value)") }
        let fixture = Self.fixture(gate)
        defer { fixture.close() }
        let shown = gate.bodyEvaluations.total
        #expect(shown >= 1, "the root ran once shown")
        _ = fixture.ledger.snapshot(matching: "Hosting.Probe", resetting: true)

        fixture.tab.set(.hidden)
        #expect(gate.isGated && gate.hosting.superview == nil, "the hosting view left the window in the hide turn")
        for _ in 0..<100 {
            probe.value += 1
            fixture.pass()
        }
        #expect(gate.bodyEvaluations.total == shown, "no body while hidden: \(gate.bodyEvaluations)")

        fixture.tab.set(.visible)
        #expect(!gate.isGated && gate.hosting.superview === gate, "back in the show turn")
        fixture.pass()
        #expect(gate.bodyEvaluations.total == shown + 1, "one body on show: \(gate.bodyEvaluations)")

        let entry = try #require(fixture.ledger.snapshot(matching: "Hosting.Probe").first)
        #expect(entry.bodyEvaluations == 1 && entry.hiddenBodyEvaluations == 0, "debug.observations: \(entry)")
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
        let gate = VisibilityGatedHostingView(owner: "Kept") { Text(verbatim: "kept") }
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
        let probe = Probe()
        let gate = VisibilityGatedHostingView(owner: "OptOut", policy: .optOut(reason: "test: runs while hidden")) {
            Text(verbatim: "\(probe.value)")
        }
        let fixture = Self.fixture(gate)
        defer { fixture.close() }

        fixture.tab.set(.hidden)
        #expect(!gate.isGated && gate.hosting.superview === gate)
        probe.value += 1
        fixture.pass()
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
        let gate = VisibilityGatedHostingView(owner: "Unfollow") { Text(verbatim: "page") }
        let fixture = Self.fixture(gate)
        defer { fixture.close() }

        fixture.tab.set(.hidden)
        #expect(gate.isGated)
        gate.unfollow()
        #expect(!gate.isGated && gate.hosting.superview === gate)
        #expect(fixture.tab.subscriberCounts.flips == 0 && fixture.tab.subscriberCounts.exemptions == 0, "no subscription is left")
    }

    @Test func aHideDrawsNothingAndKeepsNoPicture() {
        let gate = VisibilityGatedHostingView(owner: "NoPicture") { Color(red: 1, green: 0, blue: 0) }
        let fixture = Self.fixture(gate)
        defer { fixture.close() }

        fixture.tab.set(.hidden)
        #expect(gate.isGated)
        #expect(gate.subviews.isEmpty, "no picture view stands in for the page: \(gate.subviews)")
        #expect(gate.layer?.contents == nil && (gate.layer?.sublayers ?? []).allSatisfy { $0.contents == nil },
                "the hidden page keeps no bitmap")
    }

    @Test func aSnapshotOfAHiddenPageDrawsItAndLeavesItOut() throws {
        let gate = VisibilityGatedHostingView(owner: "Snapshot") { Color(red: 1, green: 0, blue: 0) }
        let fixture = Self.fixture(gate)
        defer { fixture.close() }

        fixture.tab.set(.hidden)
        let image = try #require(gate.cachedDisplayImage(), "a hidden page draws for a snapshot")
        let center = try #require(Self.pixel(of: image, x: image.width / 2, y: image.height / 2))
        #expect(center.redComponent > 0.8 && center.greenComponent < 0.25 && center.blueComponent < 0.25 && center.alphaComponent > 0.8,
                "the page, not a blank: \(center)")
        #expect(gate.isGated && gate.hosting.superview == nil, "the hosting view left again after the drawing")
    }

    @Test func textTypedInAHiddenPageStaysWhenItShows() throws {
        let gate = VisibilityGatedHostingView(owner: "Seeded") { SeededField(seed: "start") }
        let fixture = Self.fixture(gate)
        defer { fixture.close() }
        let field = try #require(Self.textFields(in: gate.hosting).first)
        #expect(field.stringValue == "start")
        #expect(fixture.window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.pass()

        fixture.tab.set(.hidden)
        fixture.pass()
        fixture.tab.set(.visible)
        fixture.pass()
        let shown = try #require(Self.textFields(in: gate.hosting).first)
        #expect(shown.stringValue == "typed", "the appear on show does not seed it again: \(shown.stringValue)")
    }

    /// A field whose text is seeded where the view is made, as gated pages do.
    struct SeededField: View {
        @State private var text: String

        init(seed: String) {
            _text = State(initialValue: seed)
        }

        var body: some View {
            TextField("", text: $text)
        }
    }

    /// The editable text fields under `view`, depth first.
    static func textFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable { found.append(field) }
        for subview in view.subviews { found += textFields(in: subview) }
        return found
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
