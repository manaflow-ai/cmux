import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Testing
import CmuxNextWakeupsTestSupport
import CmuxNextTestSupport

/// The Update Ready card and its popup (Leo 2026-10-13, cx-5dvig). At the sidebar's default width
/// the card's text is whole (it read "1.0.0 nightly 3845050 · Oct 13, 2..."), the card does not
/// repeat the popup ("See all changes" was on both), and the popup is the themed popup every
/// cmux popover is, beside the card, not AppKit's NSPopover with its stock arrow. The update is
/// staged the way `debug.updater stage` stages one in the app.
@MainActor @Suite(.closesItsWindows, .serialized) struct UpdateReadyCardLayoutTests {
    /// The highlights page, as the App's React surface reports it.
    final class Highlights: SidebarSurfaceIsland {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
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

        /// Every piece of text the card shows, with the room it has.
        func texts() -> [any ShownText] {
            func walk(_ view: NSView) -> [any ShownText] {
                guard !view.isHidden else { return [] }
                return ((view as? any ShownText).map { [$0] } ?? []) + view.subviews.flatMap(walk)
            }
            return walk(card)
        }

        /// Closes the window and the hover card window the card's popup shows in (hiding the popup
        /// only orders it out).
        func close() {
            let popup = card.hoverCards()?.cardWindow
            card.hideNotes()
            window.close()
            popup?.closeAfterTest()
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
        defer { h.close() }
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
        defer { h.close() }
        try #require(!h.card.isHidden, "the staged update shows no card")
        let shown = h.texts().map(\.stringValue)
        #expect(!shown.contains("See all changes"), "the card repeats the popup's See all changes: \(shown)")
        // The popup opens on hover only: VoiceOver still reaches the changes from the card.
        let actions = h.card.button.accessibilityCustomActions()?.map(\.name) ?? []
        #expect(actions.contains("See all changes"), "no way to the changes without a pointer: \(actions)")
    }

    @Test func thePopupIsTheThemedPopupBesideTheCardWithNoArrow() async throws {
        let h = try await make()
        defer { h.close() }
        try #require(!h.card.isHidden, "the staged update shows no card")
        h.window.orderFront(nil)
        h.card.highlights = Highlights()
        h.card.showNotes()
        let popovers = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        #expect(popovers.isEmpty, "an NSPopover (with its stock arrow) shows: \(popovers.map { type(of: $0) })")
        let popup = try #require(h.window.childWindows?.first, "no popup beside the card")
        #expect(popup.isVisible, "the popup is not on screen")
        let card = h.window.convertToScreen(h.card.convert(h.card.bounds, to: nil))
        let surface = try #require(popup as? HoverCardPanel, "the popup is not the app's one hover card").cardFrame
        #expect(surface.minX >= card.maxX - 0.5, "the popup \(surface) covers the card \(card)")
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

    /// Puts the card's popup close on `clock`, so a test moves time itself (no fixed sleeps).
    func manualClose(_ h: Harness) -> ManualClock {
        let clock = ManualClock()
        h.card.notesCloseTimer = DemandTimer(owner: "test.update-card.notes-close", clock: clock)
        return clock
    }

    /// One close wait passes: waits for the timer to sleep, moves the clock past it, and waits
    /// until the card's close check (a hop to the main actor) has run.
    func passCloseDelay(_ clock: ManualClock, _ h: Harness) async throws {
        try await clock.waitForSleeper()
        let checks = h.card.notesCloseChecks
        clock.advance(by: SidebarUpdateCardView.notesCloseDelay)
        try #require(await eventually { h.card.notesCloseChecks > checks }, "the popup's close check never ran")
    }

    /// A move over the card with no enter before it (the pointer already there, and the hover
    /// owner not told): the card's own move tracking asks the hover owner again and opens the popup.
    func moveOver(_ h: Harness, to point: (screen: CGPoint, window: CGPoint)) {
        h.card.screenPointer = { point.screen }
        PointerHover.debugPointers[ObjectIdentifier(h.window)] = PointerHover.DebugPointer(point: point.window, mouse: NSEvent.mouseLocation)
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: point.window, modifierFlags: [], timestamp: 0,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        h.card.mouseMoved(with: event!)
    }

    /// "Only the right side" opened it: a move over the card's left, middle or right opens it.
    @Test func thePointerAnywhereOnTheCardOpensThePopup() async throws {
        let h = try await make()
        defer {
            PointerHover.setDebugPointer(nil, in: h.window)
            h.close()
        }
        try #require(!h.card.isHidden, "the staged update shows no card")
        h.window.orderFront(nil)
        h.card.highlights = Highlights()
        let clock = manualClose(h)
        for fraction in [0.08, 0.5, 0.92] as [CGFloat] {
            PointerHover.setDebugPointer(nil, in: h.window)
            try #require(!h.card.isHovered, "the card is hovered with the pointer outside the window")
            moveOver(h, to: cardPoint(h, fraction: fraction))
            #expect(h.card.notesAreShown, "a move at \(fraction) of the card's width opened no popup")
            h.card.screenPointer = { CGPoint(x: -50_000, y: -50_000) }
            PointerHover.setDebugPointer(nil, in: h.window)
            try await passCloseDelay(clock, h)
            #expect(await eventually { !h.card.notesAreShown }, "the popup stayed open after the pointer left the card")
        }
    }

    /// Leaving the card diagonally toward the popup (up and right, over the sidebar list) keeps it
    /// open while the pointer is on its way, up to the corridor's limit; on the popup it stays;
    /// leaving elsewhere closes it after one short delay.
    @Test func thePopupStaysOpenWhileThePointerTravelsToIt() async throws {
        let h = try await make()
        defer {
            PointerHover.setDebugPointer(nil, in: h.window)
            h.close()
        }
        try #require(!h.card.isHidden, "the staged update shows no card")
        h.window.orderFront(nil)
        let page = Highlights()
        page.contentHeight = 300
        h.card.highlights = page
        let clock = manualClose(h)
        let start = cardPoint(h, fraction: 0.5)
        h.card.screenPointer = { start.screen }
        PointerHover.setDebugPointer(start.window, in: h.window)
        try #require(h.card.notesAreShown, "hovering the card opened no popup")
        let popup = try #require(h.window.childWindows?.first)
        let surface = try #require(popup as? HoverCardPanel, "the popup is not the app's one hover card").cardFrame
        let card = h.window.convertToScreen(h.card.convert(h.card.bounds, to: nil))
        // Past the card's top or bottom edge on the way to the popup's far part (a diagonal): off
        // the card, short of the popup and of its margin. It used to close the popup at once.
        let x = card.maxX - 20
        let y = surface.maxY > card.maxY + 24 ? card.maxY + 16 : card.minY - 16
        try #require(surface.maxY > card.maxY + 24 || surface.minY < card.minY - 24, "the popup is no taller than the card")
        let between = CGPoint(x: x, y: y)
        h.card.screenPointer = { between }
        PointerHover.setDebugPointer(h.window.convertPoint(fromScreen: between), in: h.window)
        try await passCloseDelay(clock, h)
        #expect(h.card.notesAreShown, "the popup closed while the pointer crossed to it at \(between)")
        // On the popup: it stays, and no close is pending.
        let inside = CGPoint(x: surface.midX, y: surface.midY)
        h.card.screenPointer = { inside }
        try await passCloseDelay(clock, h)
        #expect(h.card.notesAreShown, "the popup closed with the pointer on it")
        #expect(!h.card.notesCloseTimer.isScheduled, "a close is still pending with the pointer on the popup")
        // Away from both: it closes after the delay, not at once.
        h.card.screenPointer = { CGPoint(x: card.minX - 400, y: card.minY - 400) }
        h.card.pointerLeftNotes()
        #expect(h.card.notesAreShown, "the popup closed at once instead of after the delay")
        try await passCloseDelay(clock, h)
        #expect(await eventually { !h.card.notesAreShown }, "the popup stayed open after the pointer left it")
    }

    /// A pointer that stops in the corridor does not hold the popup open for good: it closes at
    /// the corridor's limit.
    @Test func aPointerParkedOnTheWayClosesThePopupAtTheLimit() async throws {
        let h = try await make()
        defer {
            PointerHover.setDebugPointer(nil, in: h.window)
            h.close()
        }
        try #require(!h.card.isHidden, "the staged update shows no card")
        h.window.orderFront(nil)
        let page = Highlights()
        page.contentHeight = 300
        h.card.highlights = page
        let clock = manualClose(h)
        let start = cardPoint(h, fraction: 0.5)
        h.card.screenPointer = { start.screen }
        PointerHover.setDebugPointer(start.window, in: h.window)
        try #require(h.card.notesAreShown, "hovering the card opened no popup")
        let popup = try #require(h.window.childWindows?.first)
        let surface = try #require(popup as? HoverCardPanel, "the popup is not the app's one hover card").cardFrame
        let card = h.window.convertToScreen(h.card.convert(h.card.bounds, to: nil))
        // Off the card on the diagonal toward the popup, and parked there.
        let parked = CGPoint(x: card.maxX - 20, y: surface.maxY > card.maxY + 24 ? card.maxY + 16 : card.minY - 16)
        h.card.screenPointer = { parked }
        PointerHover.setDebugPointer(h.window.convertPoint(fromScreen: parked), in: h.window)
        let waits = Int((SidebarUpdateCardView.notesCorridorLimit / SidebarUpdateCardView.notesCloseDelay).rounded(.up))
        for _ in 0..<(waits - 1) {
            try await passCloseDelay(clock, h)
            #expect(h.card.notesAreShown, "the popup closed before the corridor's limit")
        }
        try await passCloseDelay(clock, h)
        #expect(await eventually { !h.card.notesAreShown }, "the popup stayed open past the corridor's limit")
    }

    /// The sidebar hid the card: its popup goes with it. A popup closed under the pointer (Hide,
    /// an action, the app resigning) stays closed until the pointer leaves the card and comes back.
    @Test func aHiddenOrDismissedPopupStaysClosedUnderThePointer() async throws {
        let h = try await make()
        defer {
            PointerHover.setDebugPointer(nil, in: h.window)
            h.close()
        }
        try #require(!h.card.isHidden, "the staged update shows no card")
        h.window.orderFront(nil)
        h.card.highlights = Highlights()
        _ = manualClose(h)
        let point = cardPoint(h, fraction: 0.5)
        h.card.screenPointer = { point.screen }
        PointerHover.setDebugPointer(point.window, in: h.window)
        try #require(h.card.notesAreShown, "hovering the card opened no popup")
        h.card.hideNotes()
        #expect(await eventually { h.card.notesDismissedWhileHovered }, "the close under the pointer was not noted")
        moveOver(h, to: point)
        #expect(!h.card.notesAreShown, "a move over the card reopened the popup it was told to close")
        PointerHover.setDebugPointer(nil, in: h.window)
        PointerHover.setDebugPointer(point.window, in: h.window)
        #expect(h.card.notesAreShown, "coming back to the card opened no popup")
        h.card.isHidden = true
        #expect(!h.card.notesAreShown, "the popup stayed open after its card hid")
        #expect(!h.card.pointerIsOverCard(point.screen), "a hidden card still counts the pointer as over it")
        h.card.isHidden = false
    }

    /// Long notes: the popup is at most 60% of the window tall (the page scrolls inside it) and
    /// as wide as a menu.
    @Test func thePopupIsMenuSizedAndCappedToTheWindow() async throws {
        let h = try await make()
        defer { h.close() }
        try #require(!h.card.isHidden, "the staged update shows no card")
        h.window.orderFront(nil)
        let page = Highlights()
        page.contentHeight = 2000
        h.card.highlights = page
        h.card.showNotes()
        let popup = try #require(h.window.childWindows?.first, "no popup beside the card")
        let surface = try #require(popup as? HoverCardPanel, "the popup is not the app's one hover card").cardFrame
        #expect(surface.height <= ceil(h.window.frame.height * 0.6) + 1,
                "the popup is \(surface.height) pt tall in a \(h.window.frame.height) pt window")
        #expect((320...360).contains(surface.width), "the popup is \(surface.width) pt wide")
    }

    /// Lawrence 2026-10-20: "the hover on update ready thing to show the changelog new features
    /// only shows once, if i leave hover, and then hover comes back, then it doesnt work?" A close
    /// that finished (faded out, ordered out, page parked) left the popup window at alpha 0; the
    /// next show read `isVisible` after `addChildWindow` had already ordered it in, took it for a
    /// popup still showing, and skipped its fade-in: an invisible popup. Every return to the card
    /// shows the page again, also after a close from inside the popup (an action, See all changes).
    @Test func everyReturnToTheCardShowsThePopupAgain() async throws {
        // Every fade ends at once (a display that draws no frames), so each close has finished,
        // window ordered out, before the pointer comes back. One process per suite keeps it here.
        DisplaySleep.asleepOverride = true
        defer { DisplaySleep.asleepOverride = nil }
        let h = try await make()
        defer {
            PointerHover.setDebugPointer(nil, in: h.window)
            h.close()
        }
        try #require(!h.card.isHidden, "the staged update shows no card")
        h.window.orderFront(nil)
        let page = Highlights()
        h.card.highlights = page
        let clock = manualClose(h)
        let point = cardPoint(h, fraction: 0.5)
        let away = CGPoint(x: -50_000, y: -50_000)
        for round in 1...4 {
            h.card.screenPointer = { point.screen }
            PointerHover.setDebugPointer(point.window, in: h.window)
            try #require(h.card.isHovered, "round \(round): the card is not hovered with the pointer on it")
            let popup = try #require(h.card.notesPanel, "round \(round): hovering the card made no popup")
            #expect(h.card.notesAreShown, "round \(round): coming back to the card opened no popup")
            #expect(popup.isVisible, "round \(round): the popup is not on screen")
            #expect(popup.alphaValue > 0.99, "round \(round): the popup is on screen but invisible (alpha \(popup.alphaValue))")
            #expect(page.view.window === popup, "round \(round): the page is not in the popup")
            // Round 3 closes from inside the popup while the pointer is still on the card.
            let closedInside = round == 3
            if closedInside { h.card.hideNotes() }
            h.card.screenPointer = { away }
            PointerHover.setDebugPointer(nil, in: h.window)
            if !closedInside { try await passCloseDelay(clock, h) }
            #expect(await eventually { !popup.isVisible }, "round \(round): the popup never finished closing")
            #expect(page.view.superview === h.card.parking, "round \(round): the closed popup kept the page")
        }
    }
}
