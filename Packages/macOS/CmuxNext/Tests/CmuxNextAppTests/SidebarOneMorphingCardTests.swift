import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-10-20: "The card for the update ready (if I hover on it, the card that pops up) is
/// different from the card that shows up for other non-workspaces normally. This is not ideal.
/// Ideally it's the same card and we animate the resizing so that only one card, one offer card,
/// appears at any point in time, at all times. We do the translation thing, like the
/// `translate-y` thing."
///
/// The Update Ready highlights used to open in a window of their own (`SidebarUpdateNotesPanel`)
/// next to the app's one hover card window (`HoverCardPanel`): hovering a workspace row and then
/// the update card showed two cards at once, and going from one to the other faded one out while
/// the other faded in. These tests show both in a real window and check that there is one card
/// on screen at any time, and that going between them morphs that one card: it moves and resizes
/// from where the last card was to where the next one goes.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarOneMorphingCardTests {
    /// The highlights page, measured and drawn (as the App's React surface reports it).
    final class Highlights: SidebarSurfaceIsland {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 220))
        var contentHeight: CGFloat = 220
        var onHeightChange: (() -> Void)?
        var onAction: (() -> Void)?
        var onDismiss: (() -> Void)?
        func close() {}
    }

    /// One workspace-like row near the top of the sidebar with a small card (a stand-in for a
    /// workspace row, so the test needs no session).
    final class Row: HoverCardSource {
        weak var window: NSWindow?
        let body = NSView()
        static let id = HoverTargetID("test:row")
        init(window: NSWindow) {
            self.window = window
            body.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([body.widthAnchor.constraint(equalToConstant: 240),
                                         body.heightAnchor.constraint(equalToConstant: 90)])
        }
        var target: HoverTarget { HoverTarget(id: Self.id, window: window?.windowNumber ?? 0, delay: .zero) }
        var hoverCardWindow: NSWindow? { window }
        func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? { nil }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? {
            guard let window else { return nil }
            return CGRect(x: window.frame.minX, y: window.frame.maxY - 100, width: window.frame.width, height: 32)
        }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
            HoverCardBody(view: body, placement: .beside, themeAnchor: nil, applyTheme: {})
        }
        func hoverCardActivated(_ id: HoverTargetID) {}
        func hoverCardDeactivated(_ id: HoverTargetID) {}
    }

    struct Harness {
        let services: AppServices
        let sidebar: SidebarView
        let window: NSWindow
        let row: Row
        var card: SidebarUpdateCardView { sidebar.updateCardView }
        var cards: HoverCardCoordinator { sidebar.hoverCards }

        /// The card windows on screen beside the sidebar. A hover card being shown counts even at
        /// alpha 0, the first frame of its fade-in on a host where the fade runs; any other window
        /// (a card fading out among them) counts until it is clear.
        var shownCards: [NSWindow] {
            (window.childWindows ?? []).filter {
                $0.isVisible && ($0.alphaValue > 0.01 || ($0 as? HoverCardPanel)?.isShowingCard == true)
            }
        }

        func tearDown() {
            card.hideNotes()
            cards.dismiss(.action)
            cards.unregister(row)
            // The hover card window too when its fade-out already took it off the sidebar's window.
            var children = window.childWindows ?? []
            if let panel = cards.panel, !children.contains(panel) { children.append(panel) }
            for child in children {
                window.removeChildWindow(child)
                child.isReleasedWhenClosed = false
                child.close()
            }
            window.close()
        }
    }

    func make() async throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        _ = try DebugUpdater.run(["action": .string("stage"), "version": .string("1.0.0-nightly.3845050428001"),
                                  "changes": JSONValue(3)], services, terminate: {})
        let model = SidebarModel()
        model.updateCard = SidebarCardFeed.updateCard(services.updater)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let width = Metrics.sidebarWidth
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: width, height: 640), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 640)
        sidebar.layoutSubtreeIfNeeded()
        let row = Row(window: window)
        let harness = Harness(services: services, sidebar: sidebar, window: window, row: row)
        let deadline = ContinuousClock.now + .seconds(10)
        while harness.card.isHidden || harness.card.card == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5)) // test-only: waits for the sidebar's model task, bounded
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
        }
        window.orderFrontRegardless()
        harness.cards.appIsActive = { true }
        harness.cards.register(row)
        return harness
    }

    /// The card's surface on screen (the glass, without the window's clear band).
    private static func surface(of window: NSWindow) -> CGRect {
        guard let host = window.contentView as? PopupHostView else { return .null }
        return window.convertToScreen(host.convert(host.card.frame, to: nil))
    }

    /// Every animation in flight under `layer`, by key path.
    private static func animations(under layer: CALayer?) -> [(key: String, animation: CAAnimation)] {
        guard let layer else { return [] }
        let own = (layer.animationKeys() ?? []).compactMap { key in layer.animation(forKey: key).map { (key, $0) } }
        let masked = layer.mask.map { animations(under: $0) } ?? []
        return own + masked + (layer.sublayers ?? []).flatMap { animations(under: $0) }
    }

    /// The size an animated `bounds` (or a rounded rect `path`) starts from, if one runs under `layer`.
    private static func morphStartSizes(under layer: CALayer?) -> [CGSize] {
        animations(under: layer).compactMap { entry -> CGSize? in
            guard let basic = entry.animation as? CABasicAnimation else { return nil }
            if entry.key == "bounds", let value = basic.fromValue as? NSValue { return value.rectValue.size }
            if entry.key == "path" || entry.key == "shadowPath", let from = basic.fromValue {
                return (from as! CGPath).boundingBoxOfPath.size // swiftlint:disable:this force_cast
            }
            return nil
        }
    }

    @Test func aWorkspaceCardAndTheUpdateCardAreNeverOnScreenTogether() async throws {
        let h = try await make()
        defer { h.tearDown() }
        try #require(!h.card.isHidden, "the staged update shows no card")

        h.cards.pin(h.row.target, from: h.row)
        try #require(h.cards.isShowing(Row.id), "the workspace card did not show")
        #expect(h.shownCards.count == 1, "one workspace card shows \(h.shownCards.count) windows")

        h.card.highlights = Highlights()
        h.card.showNotes()
        #expect(h.card.notesAreShown, "hovering the update card opened no highlights")
        #expect(h.shownCards.count == 1, "the update card opened a second card beside the workspace card: \(h.shownCards.map { type(of: $0) })")
        #expect(!h.cards.isShowing(Row.id), "the workspace card still shows under the update card")

        h.cards.pin(h.row.target, from: h.row)
        #expect(h.cards.isShowing(Row.id), "the workspace card did not come back")
        #expect(!h.card.notesAreShown, "the update highlights stay open behind the workspace card")
        #expect(h.shownCards.count == 1, "the workspace card opened a second card beside the update card")
    }

    /// A card's first show fades in from clear (`HoverCardMotion.enter`). Where the fade runs (a
    /// fleet worker with a screen attached, a person's Mac), a card read in the same turn as its
    /// show is still at alpha 0, and the suite saw no card at all: about one run in five on the
    /// fleet failed every case here with `shownCards.count → 0` right after `isShowing` passed.
    /// A card fading in is on screen; one fading out still counts until it is clear.
    @Test func aCardStillFadingInCountsAsOnScreen() async throws {
        let h = try await make()
        defer { h.tearDown() }
        h.cards.pin(h.row.target, from: h.row)
        try #require(h.cards.isShowing(Row.id), "the workspace card did not show")
        let panel = try #require(h.cards.panel)
        panel.alphaValue = 0 // the fade's first frame on a host where it animates
        #expect(h.shownCards.count == 1, "a card fading in reads as no card")
    }

    @Test func goingFromAWorkspaceCardToTheUpdateCardMorphsTheOneCard() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let h = try await make()
        defer { h.tearDown() }
        try #require(!h.card.isHidden, "the staged update shows no card")

        h.cards.pin(h.row.target, from: h.row)
        let first = try #require(h.shownCards.first, "the workspace card did not show")
        let workspaceSurface = Self.surface(of: first)
        removeAllAnimations(first.contentView?.layer)
        try restBeforeTheNextShow(h.cards)

        h.card.highlights = Highlights()
        h.card.showNotes()
        let second = try #require(h.shownCards.first, "the update card did not show")
        #expect(second === first, "the update card is a different card window from the workspace card's")
        let starts = Self.morphStartSizes(under: second.contentView?.layer)
        #expect(starts.contains { abs($0.width - workspaceSurface.width) <= 1 && abs($0.height - workspaceSurface.height) <= 1 },
                "the card did not resize from the workspace card's \(workspaceSurface.size); animated sizes: \(starts)")
        let surface = Self.surface(of: second)
        #expect(abs(surface.width - 340) <= 1 && abs(surface.height - 220) <= 1, "the card does not end at the highlights' size: \(surface)")
    }

    @Test func goingFromTheUpdateCardToAWorkspaceCardMorphsBackAndParksTheHighlights() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let h = try await make()
        defer { h.tearDown() }
        try #require(!h.card.isHidden, "the staged update shows no card")

        let page = Highlights()
        h.card.highlights = page
        h.card.showNotes()
        let first = try #require(h.shownCards.first, "the update card did not show")
        let updateSurface = Self.surface(of: first)
        removeAllAnimations(first.contentView?.layer)
        try restBeforeTheNextShow(h.cards)

        h.cards.pin(h.row.target, from: h.row)
        let second = try #require(h.shownCards.first, "the workspace card did not show")
        #expect(second === first, "the workspace card is a different card window from the update card's")
        let starts = Self.morphStartSizes(under: second.contentView?.layer)
        #expect(starts.contains { abs($0.width - updateSurface.width) <= 1 && abs($0.height - updateSurface.height) <= 1 },
                "the card did not resize from the update card's \(updateSurface.size); animated sizes: \(starts)")
        #expect(page.view.superview === h.card.parking, "the highlights page did not go back to wait in the update card")
    }

    @Test func underReduceMotionTheCardChangesAtOnce() async throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let h = try await make()
        defer { h.tearDown() }
        try #require(!h.card.isHidden, "the staged update shows no card")

        h.cards.pin(h.row.target, from: h.row)
        let first = try #require(h.shownCards.first, "the workspace card did not show")
        removeAllAnimations(first.contentView?.layer)
        h.card.highlights = Highlights()
        h.card.showNotes()
        #expect(h.shownCards.count == 1, "Reduce Motion shows two cards")
        let animated = Self.morphStartSizes(under: first.contentView?.layer)
        #expect(animated.isEmpty, "the card resizes with motion under Reduce Motion: \(animated)")
    }

    /// The next show comes later than a sweep (`HoverCardTiming.sweepInterval`): a pointer that
    /// rested on one card and then went to the other, not one crossing rows, which snaps the card
    /// at once (0463b5a8e96). The two shows here run in one turn, so the panel's clock steps on.
    private func restBeforeTheNextShow(_ cards: HoverCardCoordinator) throws {
        let panel = try #require(cards.panel, "no card window")
        let rested = CACurrentMediaTime() + HoverCardTiming.sweepInterval.hoverCardSeconds + 1
        panel.now = { rested }
    }

    private func removeAllAnimations(_ layer: CALayer?) {
        guard let layer else { return }
        layer.removeAllAnimations()
        layer.mask?.removeAllAnimations()
        layer.sublayers?.forEach(removeAllAnimations)
    }
}
