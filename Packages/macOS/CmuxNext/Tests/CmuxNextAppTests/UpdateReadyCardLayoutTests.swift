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
            let needed = ceil((text as? NSTextField)?.cell?.cellSize.width ?? (text as? ChromeLabel)?.naturalSize.width ?? text.intrinsicContentSize.width)
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

    // MARK: Hover (Leo 2026-10-19)

    /// The card's frame on screen and a point in it at `fraction` of its width.
    func cardPoint(_ h: Harness, fraction: CGFloat) -> (screen: CGPoint, window: CGPoint) {
        let inWindow = h.card.convert(h.card.bounds, to: nil)
        let window = CGPoint(x: inWindow.minX + inWindow.width * fraction, y: inWindow.midY)
        return (h.window.convertPoint(toScreen: window), window)
    }

    /// Waits until `condition` holds or `timeout` passes.
    func eventually(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// "Only the right side" opened it: the pointer on the card's left, middle or right opens it.
    @Test func thePointerAnywhereOnTheCardOpensThePopup() async throws {
        let h = try await make()
        defer {
            h.card.hideNotes()
            h.window.close()
        }
        try #require(!h.card.isHidden, "the staged update shows no card")
        h.window.orderFront(nil)
        h.card.highlights = Highlights()
        for fraction in [0.08, 0.5, 0.92] as [CGFloat] {
            let point = cardPoint(h, fraction: fraction)
            h.card.screenPointer = { point.screen }
            PointerHover.setDebugPointer(point.window, in: h.window)
            #expect(h.card.notesAreShown, "the pointer at \(fraction) of the card's width opened no popup")
            h.card.screenPointer = { CGPoint(x: -50_000, y: -50_000) }
            PointerHover.setDebugPointer(nil, in: h.window)
            #expect(await eventually { !h.card.notesAreShown }, "the popup stayed open after the pointer left the card")
        }
    }

    /// Leaving the card diagonally toward the popup (up and right, over the sidebar list) keeps it
    /// open while the pointer is on its way; leaving elsewhere closes it after a short delay.
    @Test func thePopupStaysOpenWhileThePointerTravelsToIt() async throws {
        let h = try await make()
        defer {
            h.card.hideNotes()
            h.window.close()
        }
        try #require(!h.card.isHidden, "the staged update shows no card")
        h.window.orderFront(nil)
        let page = Highlights()
        page.contentHeight = 300
        h.card.highlights = page
        let start = cardPoint(h, fraction: 0.5)
        h.card.screenPointer = { start.screen }
        PointerHover.setDebugPointer(start.window, in: h.window)
        try #require(h.card.notesAreShown, "hovering the card opened no popup")
        let popup = try #require(h.window.childWindows?.first)
        let surface = PopupStyle.standard.cardFrame(inWindow: popup.frame)
        let card = h.window.convertToScreen(h.card.convert(h.card.bounds, to: nil))
        // Past the card's top or bottom edge on the way to the popup's far part (a diagonal): off
        // the card, short of the popup and of its margin. It used to close the popup at once.
        let x = card.maxX - 20
        let y = surface.maxY > card.maxY + 24 ? card.maxY + 16 : card.minY - 16
        try #require(surface.maxY > card.maxY + 24 || surface.minY < card.minY - 24, "the popup is no taller than the card")
        let between = CGPoint(x: x, y: y)
        h.card.screenPointer = { between }
        PointerHover.setDebugPointer(h.window.convertPoint(fromScreen: between), in: h.window)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(h.card.notesAreShown, "the popup closed while the pointer crossed to it at \(between)")
        // On the popup: it stays.
        let inside = CGPoint(x: surface.midX, y: surface.midY)
        h.card.screenPointer = { inside }
        try? await Task.sleep(for: .milliseconds(400))
        #expect(h.card.notesAreShown, "the popup closed with the pointer on it")
        // Away from both: it closes after the delay, not at once.
        h.card.screenPointer = { CGPoint(x: card.minX - 400, y: card.minY - 400) }
        h.card.pointerLeftNotes()
        #expect(h.card.notesAreShown, "the popup closed at once instead of after the delay")
        #expect(await eventually { !h.card.notesAreShown }, "the popup stayed open after the pointer left it")
    }

    /// Long notes: the popup is at most 60% of the window tall (the page scrolls inside it) and
    /// as wide as a menu.
    @Test func thePopupIsMenuSizedAndCappedToTheWindow() async throws {
        let h = try await make()
        defer {
            h.card.hideNotes()
            h.window.close()
        }
        try #require(!h.card.isHidden, "the staged update shows no card")
        h.window.orderFront(nil)
        let page = Highlights()
        page.contentHeight = 2000
        h.card.highlights = page
        h.card.showNotes()
        let popup = try #require(h.window.childWindows?.first, "no popup beside the card")
        let surface = PopupStyle.standard.cardFrame(inWindow: popup.frame)
        #expect(surface.height <= ceil(h.window.frame.height * 0.6) + 1,
                "the popup is \(surface.height) pt tall in a \(h.window.frame.height) pt window")
        #expect((320...360).contains(surface.width), "the popup is \(surface.width) pt wide")
    }
}
