import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence msg 19185 (NIGHTLY, a shot): a small switch sat at the sidebar's top left, over Home's house icon, just
/// above the pinned "cmux Performance Lead" row, with no card on screen. The only switch in the sidebar is the notice
/// card's (`SidebarCardSwitch`, the Tidy Up card's Always). A switch shows only while the notice card that owns it
/// shows, and then on the card's button row.
///
/// Each case runs the real ``SidebarView`` (Home and three pinned rows on top, a machine list under them) and looks at
/// every switch in the window: one that draws (no hidden ancestor, a real frame, inside the window) must lie inside a
/// notice card that shows.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarStraySwitchTests {
    static let home = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)
    static let pins = ["perf", "chromium", "chief"].map { LayoutItem(id: LayoutItemID("itm_pin_\($0)"), ref: .workspace("local:ws-pin-\($0)")) }

    /// The Tidy Up card as `AutoArchiveCoordinator.suggest` builds it: Archive, then the Always switch.
    static let tidyUp = SidebarNoticeCard(
        id: "auto-archive.suggest", symbol: "archivebox", title: "2 idle workspaces", lines: ["Sidebar group row alignment", "Restore original cmux look"],
        actions: [SidebarNoticeCard.Action(id: "archive", title: "Archive", prominent: true),
                  SidebarNoticeCard.Action(id: "always", title: "Always", isSwitch: true)],
        dismissLabel: "Not Now")
    /// A notice with a button and no switch (a tip).
    static let tip = SidebarNoticeCard(id: "tip:split", eyebrow: "Did you know?", title: "Split a pane", detail: "Cmd+D splits right.",
                                       actions: [SidebarNoticeCard.Action(id: "try", title: "Try It", prominent: true)], dismissLabel: "Hide")

    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var card: SidebarNoticeCardView { sidebar.noticeCardView }

        init(width: CGFloat = 260, height: CGFloat = 560, notice: SidebarNoticeCard? = nil) {
            _ = NSApplication.shared
            let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [SidebarStraySwitchTests.home])
            let pinned = SidebarLayoutDocument.pinnedSection(items: SidebarStraySwitchTests.pins)
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let loose = ["Original cmux-next kickoff prompt", "Sidebar group row alignment", "Restore original cmux look"]
            model = SidebarModel(sections: [
                SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
                SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
                SidebarSection(kind: .machine(machine), nodes: loose.enumerated().map { index, title in
                    .workspace(SidebarWorkspace(id: WorkspaceID("ws-loose-\(index)"), title: title))
                }),
            ])
            model.layout = SidebarLayoutDocument(sections: [top, pinned])
            var infos: [LayoutItemID: SidebarItemInfo] = [SidebarStraySwitchTests.home.id: SidebarItemInfo(title: "Home", symbol: "house")]
            for (pin, title) in zip(SidebarStraySwitchTests.pins, ["cmux Performance Lead", "cmux-chromium lead", "Chief TUI + fast iteration"]) {
                var info = SidebarItemInfo(title: title, symbol: "textformat")
                info.textOnly = true
                infos[pin.id] = info
            }
            model.itemInfo = infos
            model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
            model.noticeCard = notice
            sidebar = SidebarView(model: model, design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: width, height: height)
            window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = sidebar
            window.orderFrontRegardless()
            settle()
        }

        func close() { window.close() }

        /// Renders the model and lays the window out, as a display pass would.
        func settle() {
            sidebar.renderNow()
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            sidebar.layoutSubtreeIfNeeded()
            card.layoutSubtreeIfNeeded()
        }

        /// Shows `notice` (nil for none) and lets the card's entrance or exit run out, bounded.
        ///
        /// With `exits` false a card that leaves goes in one frame (``SidebarCardPresence/hidesNextAtOnce``): the
        /// exit's end is a Core Animation completion, which a test host that renders no frames (the Swift suite's
        /// CI Mac) never runs, so the card stayed mid-exit for the whole bounded wait (runs 41282022128 to
        /// 41303556638). These cases are about what draws once the card has gone, not about the fade.
        func show(_ notice: SidebarNoticeCard?, exits: Bool = false) async throws {
            if notice == nil, !exits { card.presence.hidesNextAtOnce = true }
            model.noticeCard = notice
            settle()
            let deadline = ContinuousClock.now + .seconds(3)
            while card.isLeaving, ContinuousClock.now < deadline {
                // Yield the main actor so AppKit can commit the exit and deliver its completion.
                try await Task.sleep(for: .milliseconds(20))
                settle()
            }
            settle()
        }

        /// Every switch control in the window that draws, with where it draws (window points).
        var drawnSwitches: [(control: NSView, rect: NSRect)] {
            guard let root = window.contentView else { return [] }
            var found: [(NSView, NSRect)] = []
            var stack: [NSView] = [root]
            while let view = stack.popLast() {
                stack.append(contentsOf: view.subviews)
                guard view is NSSwitch || view is SidebarCardSwitch, !view.isHiddenOrHasHiddenAncestor, view.window === window else { continue }
                let rect = view.convert(view.bounds, to: nil)
                guard !rect.isEmpty, rect.intersects(root.convert(root.bounds, to: nil)), Self.drawnAlpha(view) > 0 else { continue }
                found.append((view, rect))
            }
            return found
        }

        /// The notice card shows: no hidden ancestor, a real size, not fading out.
        var cardShows: Bool {
            !card.isHiddenOrHasHiddenAncestor && !card.bounds.isEmpty && !card.isLeaving && Self.drawnAlpha(card) > 0
        }

        /// Every drawn switch that is not inside the notice card's frame (a card playing its exit included).
        func outsideCard() -> [String] {
            let cardRect = card.convert(card.bounds, to: nil).insetBy(dx: -0.5, dy: -0.5)
            return drawnSwitches.compactMap { control, rect in
                !card.isHiddenOrHasHiddenAncestor && cardRect.contains(rect) ? nil
                    : "\(type(of: control)) at \(rect) outside the card at \(cardRect) (leaving \(card.isLeaving))"
            }
        }

        /// Every drawn switch that is not inside a notice card that shows.
        func strays() -> [String] {
            let cardRect = card.convert(card.bounds, to: nil).insetBy(dx: -0.5, dy: -0.5)
            return drawnSwitches.compactMap { control, rect in
                cardShows && cardRect.contains(rect) ? nil
                    : "\(type(of: control)) at \(rect) (card \(card.isHidden ? "hidden" : "unhidden") at \(card.frame), leaving \(card.isLeaving), notice \(card.notice?.id ?? "none"))"
            }
        }

        static func drawnAlpha(_ view: NSView) -> CGFloat {
            var alpha: CGFloat = 1, cursor: NSView? = view
            while let v = cursor { alpha *= v.alphaValue; cursor = v.superview }
            return alpha
        }
    }

    /// The Tidy Up card showed with its Always switch, then left (answered, Not Now or the settings change): no switch
    /// stays behind.
    @Test func aSwitchCardThatLeavesLeavesNoSwitch() async throws {
        let h = Harness()
        defer { h.close() }
        try await h.show(Self.tidyUp)
        try #require(h.cardShows, "the Tidy Up card does not show")
        try await h.show(nil)
        #expect(!h.cardShows, "the card still shows with no notice")
        #expect(h.strays().isEmpty, "a switch draws with no card: \(h.strays())")
    }

    /// The person flipped Always (Lawrence's stray switch is on): the card answers and leaves; no switch stays behind.
    @Test func flippingAlwaysThenTheCardLeavingLeavesNoSwitch() async throws {
        let h = Harness()
        defer { h.close() }
        h.model.onIntent = { [weak model = h.model] intent in
            if case .noticeAction(_, "always") = intent { model?.noticeCard = nil }
        }
        try await h.show(Self.tidyUp)
        try #require(h.cardShows, "the Tidy Up card does not show")
        h.card.presence.hidesNextAtOnce = true // the answer's exit ends in one frame (see `Harness.show`)
        try #require(h.card.actionSwitch).flip()
        try await h.show(h.model.noticeCard)
        #expect(h.model.noticeCard == nil, "Always did not answer the card")
        #expect(h.strays().isEmpty, "a switch draws after Always: \(h.strays())")
    }

    /// The switch card gave the slot to a notice without a switch: that card shows no switch.
    @Test func aSwitchCardFollowedByOneWithoutASwitchShowsNone() async throws {
        let h = Harness()
        defer { h.close() }
        try await h.show(Self.tidyUp)
        try await h.show(nil)
        try await h.show(Self.tip)
        try #require(h.cardShows, "the tip card does not show")
        #expect(h.drawnSwitches.isEmpty, "the tip card draws a switch: \(h.drawnSwitches.map(\.rect))")
        #expect(h.strays().isEmpty, "a switch draws outside the tip card: \(h.strays())")
        try await h.show(nil)
        #expect(h.strays().isEmpty, "a switch draws after the tip left: \(h.strays())")
    }

    /// A notice with a switch replaced in place by one without.
    @Test func aSwitchCardReplacedInPlaceShowsNoSwitch() async throws {
        let h = Harness()
        defer { h.close() }
        try await h.show(Self.tidyUp)
        try await h.show(Self.tip)
        #expect(h.drawnSwitches.isEmpty, "the tip card draws the Tidy Up card's switch: \(h.drawnSwitches.map(\.rect))")
    }

    /// No notice at all: no switch anywhere.
    @Test func noNoticeShowsNoSwitch() {
        let h = Harness()
        defer { h.close() }
        #expect(h.drawnSwitches.isEmpty, "a switch draws with no notice: \(h.drawnSwitches.map(\.rect))")
    }

    /// The Tidy Up card arrives while the sidebar has no size yet (a window being restored), then the window takes
    /// its size and the card leaves.
    @Test func aSwitchCardBeforeTheFirstLayoutLeavesNoSwitch() async throws {
        let h = Harness(notice: Self.tidyUp)
        defer { h.close() }
        h.sidebar.frame.size = .zero
        h.settle()
        #expect(h.strays().isEmpty, "a switch draws on a sidebar with no size: \(h.strays())")
        h.sidebar.frame.size = NSSize(width: 260, height: 560)
        h.settle()
        try await h.show(nil)
        #expect(h.strays().isEmpty, "a switch draws after the card left: \(h.strays())")
    }

    /// The sidebar narrows to nothing (closing) while the Tidy Up card shows: the switch never draws outside the card.
    @Test func aClosingSidebarDrawsNoSwitchOutsideTheCard() async throws {
        let h = Harness()
        defer { h.close() }
        try await h.show(Self.tidyUp)
        for width: CGFloat in [120, 40, 20, 0, 260] {
            h.sidebar.frame.size.width = width
            h.settle()
            #expect(h.strays().isEmpty, "at \(width) pt wide a switch draws outside the card: \(h.strays())")
        }
    }

    /// Lawrence's shot: the sidebar laid out small (a window coming up) placed the Tidy Up card at its top left, a
    /// sliver of a card; the card then left while the window took its size, keeping that place for its exit. Every
    /// other part of a sliver card draws nothing, so its switch must not draw either, at rest or mid-exit.
    @Test func aSliverCardAtTheTopLeftDrawsNoSwitch() async throws {
        let h = Harness(width: 40, height: 120)
        defer { h.close() }
        try await h.show(Self.tidyUp)
        #expect(h.outsideCard().isEmpty, "a sliver card draws its switch outside itself: \(h.outsideCard())")
        h.model.noticeCard = nil
        h.sidebar.renderNow()
        h.window.setContentSize(NSSize(width: 260, height: 560))
        h.sidebar.frame.size = NSSize(width: 260, height: 560)
        h.sidebar.needsLayout = true
        h.sidebar.layoutSubtreeIfNeeded()
        #expect(h.outsideCard().isEmpty, "mid-exit, a switch draws outside the card: \(h.outsideCard())")
        try await h.show(nil)
        #expect(h.strays().isEmpty, "a switch draws after the card left: \(h.strays())")
    }

    /// A card that leaves in a window that is not on screen goes all the same: it never stays, frozen mid-exit, to
    /// show when the window comes up.
    @Test func aCardThatLeavesOffScreenGoes() async throws {
        let h = Harness()
        defer { h.close() }
        try await h.show(Self.tidyUp)
        // WindowServer's occlusion report for the shown window, which marks it as having been on screen (a window
        // never on screen is not judged out of sight). It comes on a later run loop turn, or on a test host that
        // renders nothing never; this stands in for it, so the exit below relies on the window being out of sight,
        // not on Core Animation finishing a fade in a window nobody sees.
        _ = Motion.canAnimate(in: h.card) // starts the app's one occlusion observer (idempotent)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: h.window) // global-notice-allow: the app's one occlusion observer (FrameScheduler.watchSight) listens on .default and takes no center
        try await Task.sleep(for: .milliseconds(10)) // yields the main actor so the report is delivered on the main queue
        h.window.orderOut(nil)
        try await h.show(nil, exits: true)
        #expect(!h.card.isLeaving && h.card.isHidden, "the card is still leaving off screen (hidden \(h.card.isHidden))")
        h.window.orderFrontRegardless()
        h.settle()
        #expect(h.strays().isEmpty, "a switch draws once the window is back: \(h.strays())")
    }

    /// The card that shows the switch puts it on its button row: right of Archive, centred on its line, inside the card.
    @Test func aShownSwitchSitsOnTheCardsButtonRow() async throws {
        let h = Harness()
        defer { h.close() }
        try await h.show(Self.tidyUp)
        try #require(h.cardShows, "the Tidy Up card does not show")
        let toggle = try #require(h.card.actionSwitch)
        let button = try #require(h.card.actionButtons.first)
        let drawn = h.drawnSwitches
        #expect(!drawn.isEmpty, "the card shows no switch")
        let cardRect = h.card.convert(h.card.bounds, to: nil)
        let row = button.convert(button.bounds, to: nil)
        for (_, rect) in drawn {
            #expect(cardRect.contains(rect), "the switch \(rect) is not inside the card \(cardRect)")
            #expect(abs(rect.midY - row.midY) <= 1, "the switch \(rect) is not on the button row \(row)")
            #expect(rect.minX >= row.maxX, "the switch \(rect) is not right of Archive \(row)")
        }
        #expect(toggle.bounds.width >= toggle.fittingSize.width - 0.5, "the switch is squeezed: \(toggle.bounds) of \(toggle.fittingSize)")
        #expect(h.strays().isEmpty, "\(h.strays())")
    }
}
