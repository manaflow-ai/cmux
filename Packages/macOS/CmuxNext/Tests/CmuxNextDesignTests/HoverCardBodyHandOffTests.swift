import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// NIGHTLY crash 2026-11-25 (SIGABRT, NSGenericException "Unable to activate constraint with anchors
/// WorkspaceHoverCardView.top and NSView.top because they have no common ancestor", in
/// `HoverCardPanel.finishMorph` run by `dismiss`'s fade-out). A source reuses one body view for its cards.
/// When the coordinator retires a card window (another source's card took the window) and a fresh one shows
/// that source's body again, the view moves into the fresh window while the retired one, still fading out
/// mid-morph, kept its edge constraints on it; the morph's end activated them across two windows.
@MainActor @Suite(.serialized, .closesItsWindows) struct HoverCardBodyHandOffTests {
    private struct Fixture {
        let parent: NSWindow
        let body: NSView
        let retired: HoverCardPanel
        let fresh: HoverCardPanel
        var tab: CGRect { CGRect(x: parent.frame.minX + 40, y: parent.frame.maxY - 60, width: 180, height: 28) }

        func show(in panel: HoverCardPanel, entrance: HoverCardEntrance = .morph) {
            panel.present(body: body, anchor: tab, placement: .below, parent: parent, themeAnchor: nil, sliding: false,
                          entrance: entrance, applyTheme: {})
        }

        func tearDown() {
            retired.closeAfterTest()
            fresh.closeAfterTest()
            parent.close()
        }
    }

    private static func fixture() -> Fixture {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalToConstant: 240),
            body.heightAnchor.constraint(equalToConstant: 90),
        ])
        return Fixture(parent: parent, body: body, retired: HoverCardPanel(), fresh: HoverCardPanel())
    }

    @Test func aRetiredCardMidMorphGivesUpTheBodyAnotherCardTakes() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }

        f.show(in: f.retired)
        try #require(f.retired.activeMorph != nil, "the first card must be mid-morph for this repro")
        // The coordinator's `cardWindow(for:)`: the old window fades out, a fresh one shows the same source's body.
        f.retired.dismiss()
        f.show(in: f.fresh, entrance: .fade)

        #expect(f.body.superview === f.fresh.glass.contentView)
        #expect(f.retired.body == nil, "the retired card still claims the body the fresh card shows")
        #expect(f.retired.activeMorph == nil, "the retired card's morph outlived its body")
        #expect(f.retired.edgeConstraints.isEmpty && f.retired.sizeConstraints.isEmpty)

        // What the retired card's fade-out completion runs. Before the fix this activated the retired card's edge
        // constraints on a body now in the fresh window: an uncaught NSException, the NIGHTLY's abort.
        f.retired.finishMorph()
        f.retired.endLeaving()

        #expect(f.body.superview === f.fresh.glass.contentView)
        let pinned = f.fresh.edgeConstraints.allSatisfy(\.isActive) // outside #expect: its expansion reads a rethrows call as throwing
        #expect(pinned, "the fresh card's body lost its pins")
        #expect(f.fresh.body === f.body)
    }

    @Test func aParkedBodyTakenByAnotherCardIsNotTakenBackOut() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }

        f.show(in: f.retired, entrance: .fade)
        // The retired card's `endLeaving` parked the view (hidden, kept in the card for its next swap).
        f.retired.parkedBody = f.body
        f.body.isHidden = true
        f.retired.dismiss()
        f.show(in: f.fresh, entrance: .fade)

        #expect(f.retired.parkedBody == nil)
        #expect(f.body.isHidden == false, "the fresh card shows a body the retired card had hidden")
        // A later swap in the retired card would have removed its parked view from whatever window holds it now.
        f.retired.leavingBody = NSView()
        f.retired.endLeaving()
        #expect(f.body.superview === f.fresh.glass.contentView)
    }
}
