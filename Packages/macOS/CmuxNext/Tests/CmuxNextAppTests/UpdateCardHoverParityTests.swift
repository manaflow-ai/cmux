import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-10-19 (msg 2371): "The hover-on update ready card ... needs to have the same
/// style, behavior, and styling ... like the hover-on workspace cards. Right now it has a
/// different entry animation, which I don't like."
///
/// The Update Ready card's highlights card used to grow out of the card on the `.appear` spring
/// (the menu popup's scale-in, `openPopup`) and shrink back on close. A workspace or tab card
/// fades in while it slides a few points away from its target on the `.panel` spring, and fades
/// out without moving. These tests show both cards in real windows and compare what each one
/// actually animates, so the two cannot drift apart again.
@MainActor @Suite(.serialized, .closesItsWindows) struct UpdateCardHoverParityTests {
    /// The highlights page, measured and drawn (as the App's React surface reports it).
    final class Highlights: SidebarSurfaceIsland {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 120))
        var contentHeight: CGFloat = 120
        var onHeightChange: (() -> Void)?
        var onAction: (() -> Void)?
        var onDismiss: (() -> Void)?
        func close() {}
    }

    struct Harness {
        let services: AppServices
        let sidebar: SidebarView
        let window: NSWindow
        var card: SidebarUpdateCardView { sidebar.updateCardView }

        func tearDown() {
            card.hideNotes()
            for child in window.childWindows ?? [] { child.close() }
            // The sidebar's one hover card window, where the highlights showed (no longer a child once faded out).
            card.hoverCards()?.cardWindow?.close()
            window.close()
        }
    }

    /// What a card window's entrance or exit animates on its content layer.
    struct Played: Equatable {
        /// The translation the slide starts from (nil: no slide).
        var slideFrom: CGVector?
        /// The slide's start is a pure translation (no scale).
        var pureTranslation: Bool
        /// The slide's spring (nil: not a spring).
        var spring: [Double]?

        init(_ window: NSWindow) {
            let animation = window.contentView?.layer?.animation(forKey: "sublayerTransform")
            let from = ((animation as? CABasicAnimation)?.fromValue as? NSValue)?.caTransform3DValue
            slideFrom = from.map { CGVector(dx: $0.m41, dy: $0.m42) }
            pureTranslation = from.map { $0.m11 == 1 && $0.m22 == 1 && $0.m33 == 1 } ?? true
            spring = (animation as? CASpringAnimation).map { [$0.mass, $0.stiffness, $0.damping, $0.duration] }
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
        let harness = Harness(services: services, sidebar: sidebar, window: window)
        let deadline = ContinuousClock.now + .seconds(10)
        while harness.card.isHidden || harness.card.card == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5)) // test-only: waits for the sidebar's model task, bounded
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
        }
        window.orderFrontRegardless()
        return harness
    }

    /// A workspace card's first show beside a row of `parent`, as the sidebar shows one.
    private func workspaceCardEntrance(in parent: NSWindow) -> (played: Played, gap: CGFloat, panel: HoverCardPanel) {
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.widthAnchor.constraint(equalToConstant: 240), body.heightAnchor.constraint(equalToConstant: 90)])
        let anchor = CGRect(x: parent.frame.minX, y: parent.frame.maxY - 100, width: parent.frame.width, height: 40)
        let panel = HoverCardPanel()
        panel.present(body: body, anchor: anchor, placement: .besideRow, parent: parent, themeAnchor: nil, sliding: false, applyTheme: {})
        return (Played(panel), Self.surface(of: panel).minX - anchor.maxX, panel)
    }

    /// The card's frame on screen (the glass, without the window's clear band).
    private static func surface(of window: NSWindow) -> CGRect {
        guard let host = window.contentView as? PopupHostView else { return .null }
        return window.convertToScreen(host.convert(host.card.frame, to: nil))
    }

    @Test func theUpdateCardEntersExactlyLikeAWorkspaceCard() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let h = try await make()
        defer { h.tearDown() }
        try #require(!h.card.isHidden, "the staged update shows no card")

        let workspace = workspaceCardEntrance(in: h.window)
        defer { workspace.panel.close() }
        #expect(workspace.played.slideFrom != nil, "the workspace card played no entrance to compare with")

        h.card.highlights = Highlights()
        h.card.showNotes()
        let popup = try #require(h.window.childWindows?.first { $0 !== workspace.panel }, "no update hover card")
        let update = Played(popup)
        #expect(update.pureTranslation, "the update card scales in (its own popup entrance), not the hover cards' slide")
        #expect(update == workspace.played, "the update card enters with \(update), a workspace card with \(workspace.played)")
    }

    @Test func theUpdateCardSitsAtTheWorkspaceCardsGap() async throws {
        let h = try await make()
        defer { h.tearDown() }
        try #require(!h.card.isHidden, "the staged update shows no card")
        let workspace = workspaceCardEntrance(in: h.window)
        defer { workspace.panel.close() }

        h.card.highlights = Highlights()
        h.card.showNotes()
        let popup = try #require(h.window.childWindows?.first { $0 !== workspace.panel }, "no update hover card")
        let card = h.window.convertToScreen(h.card.convert(h.card.bounds, to: nil))
        let surface = Self.surface(of: popup)
        #expect(abs((surface.minX - card.maxX) - workspace.gap) <= 0.5,
                "the update card sits \(surface.minX - card.maxX) pt from its card, a workspace card \(workspace.gap) pt from its row")
        #expect(abs(surface.maxY - card.maxY) <= 1, "the update card is not top-aligned with its card")
    }

    @Test func theUpdateCardFadesOutWithoutShrinking() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let h = try await make()
        defer { h.tearDown() }
        try #require(!h.card.isHidden, "the staged update shows no card")
        h.card.highlights = Highlights()
        h.card.showNotes()
        let popup = try #require(h.window.childWindows?.first, "no update hover card")
        popup.contentView?.layer?.removeAllAnimations()
        h.card.hideNotes()
        let exit = Played(popup)
        #expect(exit.slideFrom == nil && exit.spring == nil && exit.pureTranslation,
                "the update card moves or shrinks as it hides (\(exit)); a workspace card only fades out")
    }

    @Test func theUpdateCardHasItsContentOnItsFirstFrame() async throws {
        let h = try await make()
        defer { h.tearDown() }
        try #require(!h.card.isHidden, "the staged update shows no card")

        // A page that has not drawn yet shows no empty card.
        let unmeasured = Highlights()
        unmeasured.contentHeight = 0
        h.card.highlights = unmeasured
        h.card.showNotes()
        #expect(h.window.childWindows?.contains { $0.isVisible } != true, "an empty update card showed")

        // A drawn page is in the card, at its height, when the card first shows.
        let highlights = Highlights()
        h.card.highlights = highlights
        h.card.showNotes()
        let popup = try #require(h.window.childWindows?.first { $0.isVisible }, "no update hover card")
        #expect(highlights.view.window === popup, "the card showed before its content moved in")
        #expect(abs(Self.surface(of: popup).height - 120) <= 1, "the card is not the page's height")
    }
}
