import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The Update Ready card and its popup (Leo 2026-10-13, cx-5dvig). At the sidebar's default width
/// the card's text is whole (it read "1.0.0 nightly 3845050 · Oct 13, 2..."), the card does not
/// repeat the popup ("See all changes" was on both), and the popup is the themed popup every
/// cmux popover is, beside the card, not AppKit's NSPopover with its stock arrow. The update is
/// staged the way `debug.updater stage` stages one in the app.
@MainActor @Suite(.serialized) struct UpdateReadyCardLayoutTests {
    /// The highlights page, as the App's React surface reports it.
    final class Highlights: SidebarSurfaceIsland {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        var contentHeight: CGFloat = 120
        var onHeightChange: (() -> Void)?
        var onAction: (() -> Void)?
        func close() {}
    }

    struct Harness {
        let services: AppServices
        let sidebar: SidebarView
        let window: NSWindow
        var card: SidebarUpdateCardView { sidebar.updateCardView }

        /// Every piece of text the card shows, with the room it has.
        func texts() -> [any ShownText] {
            func walk(_ view: NSView) -> [any ShownText] {
                guard !view.isHidden else { return [] }
                return ((view as? any ShownText).map { [$0] } ?? []) + view.subviews.flatMap(walk)
            }
            return walk(card)
        }

        /// Waits for the sidebar to show the model's card (it follows the model on a task).
        func cardShows(within timeout: Duration = .seconds(10)) async {
            let deadline = ContinuousClock.now + timeout
            while card.isHidden || card.card == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
                sidebar.needsLayout = true
                sidebar.layoutSubtreeIfNeeded()
            }
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
        await harness.cardShows()
        return harness
    }

    @Test func theCardsTextIsWholeAtTheDefaultSidebarWidth() async throws {
        let h = try await make()
        defer { h.window.close() }
        try #require(h.services.updater.readyCard != nil, "the staged update shows no card")
        #expect(!h.card.isHidden)
        let texts = h.texts()
        #expect(texts.contains { $0.stringValue == "Update Ready" })
        #expect(texts.contains { $0.stringValue.contains("3845050") }, "the card names the build: \(texts.map(\.stringValue))")
        for text in texts where !text.stringValue.isEmpty {
            // The text's own size, with the label's insets.
            let needed = ceil((text as? NSTextField)?.cell?.cellSize.width ?? text.intrinsicContentSize.width)
            #expect(needed <= text.frame.width + 0.5,
                    "\"\(text.stringValue)\" needs \(needed) pt and has \(text.frame.width) pt at a \(Metrics.sidebarWidth) pt sidebar")
        }
    }

    @Test func theCardLeavesSeeAllChangesToItsPopup() async throws {
        let h = try await make()
        defer { h.window.close() }
        try #require(!h.card.isHidden, "the staged update shows no card")
        let shown = h.texts().map(\.stringValue)
        #expect(!shown.contains("See all changes"), "the card repeats the popup's See all changes: \(shown)")
        // The popup opens on hover only: VoiceOver still reaches the changes from the card.
        let actions = h.card.button.accessibilityCustomActions()?.map(\.name) ?? []
        #expect(actions.contains("See all changes"), "no way to the changes without a pointer: \(actions)")
    }

    @Test func thePopupIsTheThemedPopupBesideTheCardWithNoArrow() async throws {
        let h = try await make()
        defer {
            h.card.hideNotes()
            h.window.close()
        }
        try #require(!h.card.isHidden, "the staged update shows no card")
        h.window.orderFront(nil)
        h.card.highlights = Highlights()
        h.card.showNotes()
        let popovers = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        #expect(popovers.isEmpty, "an NSPopover (with its stock arrow) shows: \(popovers.map { type(of: $0) })")
        let popup = try #require(h.window.childWindows?.first, "no popup beside the card")
        #expect(popup.isVisible, "the popup is not on screen")
        let card = h.window.convertToScreen(h.card.convert(h.card.bounds, to: nil))
        let surface = PopupStyle.standard.cardFrame(inWindow: popup.frame)
        #expect(surface.minX >= card.maxX, "the popup \(surface) covers the card \(card)")
        #expect(abs(surface.maxY - card.maxY) <= 1, "the popup's top \(surface.maxY) is not the card's \(card.maxY)")
        #expect(abs(surface.height - 120) <= 1, "the popup is not the page's height: \(surface.height)")
    }
}
