import AppKit
import CmuxNextCompat
@testable import CmuxNextOnboarding
import Testing

/// The Computer Use setup sheet (user 2026-10-27, "improve this ui", and the
/// drag panel "decoupled" from System Settings): the sheet fits its cards,
/// each card shows its own state, Done waits for both grants, the footer
/// buttons keep their regular size, and the drag panel docks to System
/// Settings (else to the sheet) and goes once the grant lands.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ComputerUseSheetTests {
    // MARK: Fixtures

    /// A System Settings window that tests move by hand.
    @MainActor final class FakeLocator: SystemSettingsWindowLocating {
        var current: NSRect?
        private(set) var reads = 0
        init(_ frame: NSRect?) { current = frame }
        func frame() -> NSRect? {
            reads += 1
            return current
        }
    }

    private struct Sheet {
        let model: OnboardingModel
        let source: MockComputerUsePermissionSource
        let controller: OnboardingWindowController
        var window: NSWindow { controller.window! }
    }

    private func makeSheet(_ permissions: ComputerUsePermissions) -> Sheet {
        let services = MockOnboardingServices()
        let source = MockComputerUsePermissionSource(current: permissions)
        services.computerUseSource = source
        let model = OnboardingModel(services: services, step: .computerUse)
        return Sheet(model: model, source: source, controller: OnboardingWindowController(model: model))
    }

    /// Starts the step and waits until it shows `permissions`.
    private func start(_ sheet: Sheet, until permissions: ComputerUsePermissions) async {
        sheet.model.computerUse.start()
        for await value in ObservationStream({ sheet.model.computerUse.permissions }) where value == permissions { break }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    private func layOut(_ sheet: Sheet) -> (step: ComputerUseStepView, footer: OnboardingFooter) {
        let content = sheet.window.contentView!
        let step = find(ComputerUseStepView.self, in: content)!
        let footer = find(OnboardingFooter.self, in: content)!
        step.render()
        footer.render()
        content.layoutSubtreeIfNeeded()
        return (step, footer)
    }

    nonisolated static let both = ComputerUsePermissions(accessibility: true, screenRecording: true)
    nonisolated static let accessibilityOnly = ComputerUsePermissions(accessibility: true, screenRecording: false)
    nonisolated static let screenOnly = ComputerUsePermissions(accessibility: false, screenRecording: true)

    // MARK: Cards

    @Test(arguments: [
        (ComputerUsePermissions.none, PermissionCardState.next, PermissionCardState.later),
        (ComputerUsePermissions.off, .next, .later),
        (ComputerUseSheetTests.accessibilityOnly, .granted, .next),
        (ComputerUseSheetTests.screenOnly, .next, .granted),
        (ComputerUseSheetTests.both, .granted, .granted),
    ])
    func cardsShowTheNextGrantAndTheGivenOnes(_ permissions: ComputerUsePermissions,
                                              _ accessibility: PermissionCardState, _ screen: PermissionCardState) {
        #expect(PermissionCardState(pane: .accessibility, permissions: permissions) == accessibility)
        #expect(PermissionCardState(pane: .screenRecording, permissions: permissions) == screen)
    }

    /// A granted card shows the check and "Allowed", the next one the filled
    /// Allow, a later one the bordered Allow; no number badge anywhere.
    @Test func cardsShowTheirStateOnTheRight() async throws {
        let sheet = makeSheet(Self.accessibilityOnly)
        await start(sheet, until: Self.accessibilityOnly)
        let (step, _) = layOut(sheet)
        let accessibility = try #require(step.rows[.accessibility])
        let screen = try #require(step.rows[.screenRecording])
        #expect(!accessibility.allowed.isHidden && accessibility.primaryAllow.isHidden && accessibility.secondaryAllow.isHidden)
        #expect(screen.allowed.isHidden && !screen.primaryAllow.isHidden && screen.secondaryAllow.isHidden)
        #expect(screen.primaryAllow is OnboardingAccentButton)
        #expect(find(OnboardingKeycap.self, in: step) == nil)
    }

    // MARK: Footer

    @Test func doneWaitsForBothGrantsAndSkipReadsNotNow() async {
        let sheet = makeSheet(.none)
        var ended: Bool?
        sheet.model.onEnd = { ended = $0 }
        await start(sheet, until: .none)
        let (_, footer) = layOut(sheet)
        let done = footer.buttons[2]
        #expect(sheet.model.primaryTitle == OnboardingStrings.done)
        #expect(sheet.model.skipTitle == OnboardingStrings.notNow)
        #expect(footer.buttons[1].title == OnboardingStrings.notNow)
        #expect(!sheet.model.canGoNext)
        #expect(!done.isEnabled)
        sheet.model.next()
        #expect(ended == nil)

        sheet.source.current = Self.both
        for await granted in ObservationStream({ sheet.model.computerUse.allGranted }) where granted { break }
        footer.render()
        #expect(done.isEnabled)
        sheet.model.next()
        #expect(ended == true)
    }

    /// The sheet's buttons keep the regular onboarding size: the large
    /// control height and the 13 pt body font.
    @Test func footerButtonsAreRegularSize() async {
        let sheet = makeSheet(.none)
        await start(sheet, until: .none)
        let (_, footer) = layOut(sheet)
        for button in footer.buttons.dropFirst() {
            #expect(button.frame.height >= 28, "\(button.title) is \(button.frame.height) pt tall")
            let font = button.attributedTitle.length > 0
                ? button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : button.font
            #expect((font?.pointSize ?? 0) >= 13, "\(button.title) uses \(font?.pointSize ?? 0) pt")
        }
    }

    // MARK: Size

    /// The sheet fits its content: shorter than the shared 520 pt window,
    /// with no empty band between the last card or note and the footer, and
    /// nothing overlapping the footer, in every state.
    @Test(arguments: [ComputerUsePermissions.none, .off, ComputerUseSheetTests.accessibilityOnly, ComputerUseSheetTests.both,
                      .helperVersionMismatch, .helperFailed])
    func sheetFitsItsContent(_ permissions: ComputerUsePermissions) async throws {
        let sheet = makeSheet(permissions)
        await start(sheet, until: permissions)
        let (step, footer) = layOut(sheet)
        let content = sheet.window.contentView!
        #expect(content.frame.height < OnboardingMetrics.windowSize.height)
        #expect(content.frame.size == StandardComputerUse.windowSize)
        let visible = step.subviews.flatMap { ($0 as? NSStackView)?.arrangedSubviews ?? [] }.filter { !$0.isHidden }
        let lowest = visible.map { $0.convert($0.bounds, to: content) }.max { a, b in
            // Bottom of the content in a flipped or unflipped root.
            content.isFlipped ? a.maxY < b.maxY : a.minY > b.minY
        }
        let bottom = try #require(lowest)
        let footerFrame = footer.convert(footer.bounds, to: content)
        let gap = content.isFlipped ? footerFrame.minY - bottom.maxY : bottom.minY - footerFrame.maxY
        #expect(gap >= 8, "content overlaps the footer: \(gap) pt")
        // A helper that did not answer hides the cards for its note and Restart: only that state may leave room.
        if !permissions.helperFailed { #expect(gap <= 72, "\(gap) pt of empty space above the footer") }
    }

    // MARK: Drag panel placement

    nonisolated static let screen = NSRect(x: 0, y: 0, width: 1512, height: 944)

    @Test func panelDocksCenteredUnderTheWindow() {
        let placement = HelperPanelPlacement(gap: 10)
        let window = NSRect(x: 400, y: 300, width: 700, height: 600)
        let origin = placement.origin(panel: NSSize(width: 500, height: 60), anchor: window, visible: Self.screen)
        #expect(origin == NSPoint(x: 500, y: 230))
    }

    @Test func panelGoesAboveWhenNoRoomBelowAndInsideWhenNoRoomAtAll() {
        let placement = HelperPanelPlacement(gap: 10)
        let size = NSSize(width: 500, height: 60)
        let low = NSRect(x: 400, y: 20, width: 700, height: 600)
        #expect(placement.origin(panel: size, anchor: low, visible: Self.screen) == NSPoint(x: 500, y: 630))
        let tall = NSRect(x: 400, y: 20, width: 700, height: 900)
        #expect(placement.origin(panel: size, anchor: tall, visible: Self.screen) == NSPoint(x: 500, y: 30))
    }

    @Test func panelStaysOnScreen() {
        let placement = HelperPanelPlacement(gap: 10)
        let leftEdge = NSRect(x: -200, y: 300, width: 400, height: 500)
        #expect(placement.origin(panel: NSSize(width: 500, height: 60), anchor: leftEdge, visible: Self.screen).x == 10)
    }

    @Test func locatorReadsTheFrontSettingsWindowInAppKitCoordinates() {
        let bounds = { (x: Double, y: Double, w: Double, h: Double) -> NSDictionary in
            CGRect(x: x, y: y, width: w, height: h).dictionaryRepresentation
        }
        let list: [[String: Any]] = [
            [kCGWindowOwnerPID as String: 7, kCGWindowLayer as String: 0, kCGWindowBounds as String: bounds(0, 0, 900, 700)],
            [kCGWindowOwnerPID as String: 42, kCGWindowLayer as String: 25, kCGWindowBounds as String: bounds(0, 0, 900, 700)],
            [kCGWindowOwnerPID as String: 42, kCGWindowLayer as String: 0, kCGWindowBounds as String: bounds(10, 10, 40, 20)],
            [kCGWindowOwnerPID as String: 42, kCGWindowLayer as String: 0, kCGWindowBounds as String: bounds(300, 100, 700, 600)],
            [kCGWindowOwnerPID as String: 42, kCGWindowLayer as String: 0, kCGWindowBounds as String: bounds(0, 0, 800, 800)],
        ]
        let frame = SystemSettingsWindowLocator.frame(in: list, primaryHeight: 944) { $0 == 42 }
        #expect(frame == NSRect(x: 300, y: 244, width: 700, height: 600))
        #expect(SystemSettingsWindowLocator.frame(in: list, primaryHeight: 944) { $0 == 99 } == nil)
    }

    // MARK: Drag panel dock

    private func makeDock(_ locator: FakeLocator) -> (HelperDragPanelDock, NSWindow) {
        let sheet = NSWindow(contentRect: NSRect(x: 300, y: 400, width: 600, height: 404), styleMask: [.titled], backing: .buffered, defer: true)
        let panel = HelperDragPanel(appURL: URL(fileURLWithPath: "/Applications/cmux Computer Use.app")) {}
        let dock = HelperDragPanelDock(panel: panel, sheet: sheet, locator: locator, visibleFrames: { [Self.screen] })
        return (dock, sheet)
    }

    @Test func dockFollowsSystemSettingsAndFallsBackToTheSheet() {
        let settings = NSRect(x: 400, y: 300, width: 700, height: 600)
        let locator = FakeLocator(settings)
        let (dock, sheet) = makeDock(locator)
        defer { dock.close() }
        let placement = HelperPanelPlacement()
        dock.reposition()
        #expect(dock.anchor == .systemSettings(settings))
        #expect(dock.panel.parent == nil)
        #expect(dock.panel.frame.origin == placement.origin(panel: dock.panel.frame.size, anchor: settings, visible: Self.screen))

        // The person drags System Settings: the release docks the panel under its new frame.
        let moved = settings.offsetBy(dx: -120, dy: 80)
        locator.current = moved
        dock.pointerEvent(.leftMouseUp, timestamp: 10)
        #expect(dock.anchor == .systemSettings(moved))
        #expect(dock.panel.frame.origin == placement.origin(panel: dock.panel.frame.size, anchor: moved, visible: Self.screen))

        // System Settings closed: the panel rides under the sheet as its child window.
        locator.current = nil
        dock.pointerEvent(.leftMouseUp, timestamp: 11)
        #expect(dock.anchor == .sheet)
        #expect(dock.panel.parent === sheet)
        #expect(dock.panel.frame.maxY <= sheet.frame.minY)

        // Back: it leaves the sheet again.
        locator.current = settings
        dock.pointerEvent(.leftMouseDragged, timestamp: 12)
        #expect(dock.panel.parent == nil)
        #expect(dock.anchor == .systemSettings(settings))
    }

    @Test func pointerMovesReadAtMostOncePerInterval() {
        let locator = FakeLocator(NSRect(x: 400, y: 300, width: 700, height: 600))
        let (dock, _) = makeDock(locator)
        defer { dock.close() }
        dock.pointerEvent(.mouseMoved, timestamp: 100)
        dock.pointerEvent(.mouseMoved, timestamp: 100 + HelperDragPanelDock.moveInterval / 2)
        #expect(locator.reads == 1)
        dock.pointerEvent(.mouseMoved, timestamp: 100 + HelperDragPanelDock.moveInterval * 1.5)
        #expect(locator.reads == 2)
    }

    /// Allow docks the drag panel; the grant landing hides it.
    @Test func dragPanelGoesOnceTheGrantLands() async throws {
        let sheet = makeSheet(.none)
        await start(sheet, until: .none)
        let content = sheet.window.contentView!
        let step = try #require(find(ComputerUseStepView.self, in: content))
        sheet.model.computerUse.allow(.accessibility)
        step.render()
        let dock = try #require(step.dock)
        let panel = dock.panel
        #expect(panel.isVisible)
        #expect(dock.anchor != nil)

        sheet.source.current = Self.accessibilityOnly
        for await helping in ObservationStream({ sheet.model.computerUse.helping }) where helping == nil { break }
        step.render()
        #expect(step.dock == nil)
        #expect(!panel.isVisible)
        #expect(panel.parent == nil)
    }
}
