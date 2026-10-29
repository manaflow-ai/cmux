import AppKit
import CmuxNextAgentPermissions
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextOnboarding
import Foundation
import Testing
@testable import CmuxNextApp

/// The Computer Use window: one primary Allow on the next missing row, the
/// row waits gray while its drag panel shows, the window comes back when the
/// grant lands, a done state, Return as the primary action, the entry points
/// that open it, the drag panel (where it docks, how it follows System Settings,
/// its back button, its line and its arrow), and the rows' icons.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComputerUseSetupWindowTests {
    private func make(_ current: ComputerUsePermissions = .none,
                      helper: URL? = URL(fileURLWithPath: "/Applications/cmux Computer Use.app"))
        -> (MockComputerUsePermissionSource, ComputerUseStepModel) {
        let source = MockComputerUsePermissionSource(current: current, helperAppURL: helper)
        let model = ComputerUseStepModel(source: source)
        model.start()
        return (source, model)
    }

    /// Waits until the model applied what the source pushed.
    private func settle(_ model: ComputerUseStepModel, _ condition: @MainActor () -> Bool) async {
        for await _ in ObservationStream({ model.permissions }) where condition() { return }
    }

    @Test func onlyTheNextMissingRowIsPrimary() async {
        let (source, model) = make()
        defer { model.stop() }
        await settle(model) { true }
        #expect(model.nextPane == .accessibility)
        #expect(model.isPrimary(.accessibility))
        #expect(!model.isPrimary(.screenRecording))
        #expect(ComputerUseSetupView.control(.screenRecording, model) == .allow(primary: false))

        source.current.accessibility = true
        await settle(model) { model.permissions.accessibility }
        #expect(model.nextPane == .screenRecording)
        #expect(model.isPrimary(.screenRecording))
        #expect(ComputerUseSetupView.control(.accessibility, model) == .done)
        #expect(ComputerUseSetupView.control(.screenRecording, model) == .allow(primary: true))
        #expect(!model.allGranted)
    }

    @Test func allowOpensTheListAndTheRowWaitsGray() async {
        let (source, model) = make()
        defer { model.stop() }
        await settle(model) { true }
        model.allow(.accessibility)
        #expect(source.opened == [.accessibility])
        #expect(model.helping == .accessibility)
        #expect(!model.isPrimary(.accessibility), "the row's Allow goes gray while the panel shows")
        #expect(ComputerUseSetupView.control(.accessibility, model) == .allow(primary: false))
    }

    @Test func theGrantLandingClosesThePanelAndBringsTheWindowBack() async {
        let (source, model) = make()
        defer { model.stop() }
        await settle(model) { true }
        model.allow(.accessibility)
        source.current.accessibility = true
        await settle(model) { model.permissions.accessibility }
        #expect(model.helping == nil)
        #expect(model.comebacks == 1)
        #expect(model.isPrimary(.screenRecording))

        model.allow(.screenRecording)
        source.current.screenRecording = true
        await settle(model) { model.permissions.screenRecording }
        #expect(model.comebacks == 2)
        #expect(model.allGranted)
        #expect(model.nextPane == nil)
        #expect(ComputerUseSetupView.noteText(model) == nil)
    }

    @Test func aGrantWithoutThePanelDoesNotPullTheWindowForward() async {
        let (source, model) = make()
        defer { model.stop() }
        await settle(model) { true }
        source.current.accessibility = true
        await settle(model) { model.permissions.accessibility }
        #expect(model.comebacks == 0)
    }

    @Test func aDropReadsTheGrantsAgain() async {
        let (source, model) = make()
        defer { model.stop() }
        await settle(model) { true }
        model.helperDropped()
        #expect(source.recheckCount == 0, "no panel, no read")
        model.allow(.screenRecording)
        model.helperDropped()
        #expect(source.recheckCount == 1)
    }

    @Test func returnAllowsTheNextRowThenDoneCloses() async {
        let services = MockOnboardingServices()
        let source = MockComputerUsePermissionSource()
        services.computerUseSource = source
        let window = OnboardingModel(services: services, step: .computerUse)
        let ended = Log()
        window.onEnd = { if $0 { ended.count += 1 } }
        window.stepDidAppear()
        defer { window.leave() }
        await settle(window.computerUse) { true }

        window.next()
        #expect(source.opened == [.accessibility])
        window.next()
        #expect(source.opened == [.accessibility], "Return does nothing while the row waits for its grant")
        #expect(ended.count == 0)

        source.current = ComputerUsePermissions(accessibility: true, screenRecording: true)
        await settle(window.computerUse) { window.computerUse.allGranted }
        window.next()
        #expect(ended.count == 1)
    }

    @Test func aFailedHelperHasNoPrimaryRowAndReturnRestarts() async {
        let services = MockOnboardingServices()
        let source = MockComputerUsePermissionSource(current: .helperFailed)
        services.computerUseSource = source
        let window = OnboardingModel(services: services, step: .computerUse)
        window.stepDidAppear()
        defer { window.leave() }
        await settle(window.computerUse) { window.computerUse.permissions.helperFailed }
        #expect(window.computerUse.nextPane == nil)
        #expect(ComputerUseSetupView.control(.accessibility, window.computerUse) == .hidden)
        #expect(ComputerUseSetupView.noteText(window.computerUse) == OnboardingStrings.computerUseHelperFailed)
        window.next()
        #expect(source.restartCount == 1)
        #expect(source.opened.isEmpty)
    }

    @Test func noSignedHelperSaysUnavailableAndOpensNothing() async {
        let (source, model) = make(helper: nil)
        defer { model.stop() }
        await settle(model) { true }
        model.allow(.accessibility)
        #expect(model.unavailable)
        #expect(source.opened.isEmpty)
        #expect(!model.isPrimary(.accessibility))
        #expect(ComputerUseSetupView.noteText(model) == OnboardingStrings.computerUseHelperUnavailable)
    }

    // MARK: Entry points

    /// Counts and records what a closure saw (a class, so `@MainActor` closures can change it).
    private final class Log {
        var count = 0
        var urls: [URL] = []
    }

    @Test func thePresenterOpensTheComputerUseWindowAndReusesIt() {
        let presented = Log()
        let presenter = OnboardingWindowPresenter(makeModel: { step in
            let services = MockOnboardingServices()
            services.computerUseSource = MockComputerUsePermissionSource()
            return OnboardingModel(services: services, step: step)
        }, present: { _ in presented.count += 1 })
        presenter.show(step: .computerUse)
        let first = presenter.controller
        #expect(first?.model.step == .computerUse)
        #expect(first?.window?.contentView?.frame.size == ComputerUseSetupView.size)
        presenter.show(step: .computerUse)
        #expect(presenter.controller === first, "a second open brings the same window forward")
        #expect(presented.count == 2)
        first?.close()
    }

    @Test func continueOnAComputerUseCardOpensTheWindowNotTheList() {
        let setup = ComputerUseSetup(inputs: { .init(disabledByPolicy: false, enabled: true, helper: .off) },
                                     configuration: { nil }, resolveHelper: { _ in nil })
        let log = Log()
        let opener = SystemPermissionOpener(setup: setup, showComputerUse: { log.count += 1 }, openURL: { log.urls.append($0) })
        opener.open(.computerUse, target: nil)
        opener.open(.accessibility, target: nil)
        opener.open(.screenRecording, target: nil)
        #expect(log.count == 3)
        #expect(log.urls.isEmpty)
        opener.open(.fullDiskAccess, target: nil)
        #expect(log.count == 3)
        #expect(log.urls == [PermissionKind.fullDiskAccess.settingsURL].compactMap { $0 })
    }

    // MARK: The drag panel

    @Test func thePanelDocksAsTheNextRowOfTheList() {
        let size = NSSize(width: HelperDragPanel.width, height: 100)
        let settings = NSRect(x: 100, y: 200, width: 723, height: 625)
        let docked = SystemSettingsWindow.dockedFrame(panel: size, iconCenter: HelperDragPanel.iconCenter, settings: settings, visible: nil)
        #expect(docked.minX + HelperDragPanel.iconCenter == settings.minX + SystemSettingsWindow.listIconCenter,
                "the helper's icon stands in the list's icon column")
        #expect(docked.minX + HelperDragPanel.rowLeading == settings.minX + SystemSettingsWindow.listLeading, "the row starts with the list's rows")
        #expect(docked.minX + HelperDragPanel.rowLeading + SystemSettingsWindow.listWidth == settings.minX + SystemSettingsWindow.listTrailing,
                "the row ends with the list's rows")
        #expect(docked.minY == settings.minY + SystemSettingsWindow.inset)
        // Kept on screen.
        let visible = NSRect(x: 0, y: 40, width: 1440, height: 860)
        let low = NSRect(x: 1000, y: 0, width: 723, height: 625)
        let kept = SystemSettingsWindow.dockedFrame(panel: size, iconCenter: HelperDragPanel.iconCenter, settings: low, visible: visible)
        #expect(visible.contains(kept))
    }

    @Test func aKnownListPutsThePanelsTopJustUnderIt() {
        let size = NSSize(width: HelperDragPanel.width, height: 100)
        let settings = NSRect(x: 100, y: 200, width: 723, height: 625)
        let bottom = SystemSettingsWindow.dockedFrame(panel: size, iconCenter: HelperDragPanel.iconCenter, settings: settings, visible: nil)
        let under = SystemSettingsWindow.dockedFrame(panel: size, iconCenter: HelperDragPanel.iconCenter, settings: settings,
                                                     listBottom: 416, visible: nil)
        #expect(under.maxY == settings.maxY - 416 - SystemSettingsWindow.listGap, "the panel's top is a small gap under the list")
        #expect(under.minX == bottom.minX, "the icon column does not change")
        // A list that runs past the window docks at the bottom; one scrolled up stays under the toolbar.
        let long = SystemSettingsWindow.dockedFrame(panel: size, iconCenter: HelperDragPanel.iconCenter, settings: settings,
                                                    listBottom: 2000, visible: nil)
        #expect(long == bottom)
        let high = SystemSettingsWindow.dockedFrame(panel: size, iconCenter: HelperDragPanel.iconCenter, settings: settings,
                                                    listBottom: -300, visible: nil)
        #expect(high.maxY == settings.maxY - SystemSettingsWindow.toolbarHeight)
    }

    @Test func theWindowListPicksTheFrontmostSettingsWindow() {
        let list: [[String: Any]] = [
            [kCGWindowOwnerName as String: "System Settings", kCGWindowLayer as String: 0, kCGWindowNumber as String: 1,
             kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 40, height: 40).dictionaryRepresentation],
            [kCGWindowOwnerName as String: "Finder", kCGWindowLayer as String: 0, kCGWindowNumber as String: 2,
             kCGWindowBounds as String: CGRect(x: 10, y: 10, width: 800, height: 600).dictionaryRepresentation],
            [kCGWindowOwnerName as String: "System Settings", kCGWindowLayer as String: 25, kCGWindowNumber as String: 3,
             kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 800, height: 600).dictionaryRepresentation],
            [kCGWindowOwnerName as String: "System Settings", kCGWindowLayer as String: 0, kCGWindowNumber as String: 4,
             kCGWindowOwnerPID as String: 321, kCGWindowBounds as String: CGRect(x: 50, y: 60, width: 800, height: 600).dictionaryRepresentation],
        ]
        let found = SystemSettingsWindow.pick(list, owners: SystemSettingsWindow.ownerNames())
        #expect(found == SettingsWindowMatch(id: 4, bounds: CGRect(x: 50, y: 60, width: 800, height: 600), pid: 321))
        let frame = SystemSettingsWindow.appKitFrame(CGRect(x: 50, y: 60, width: 800, height: 600), primaryHeight: 1000)
        #expect(frame == NSRect(x: 50, y: 340, width: 800, height: 600))
    }

    @Test func oneWindowsEntrySaysWhereItIs() {
        let bounds = CGRect(x: 50, y: 60, width: 723, height: 625)
        #expect(SystemSettingsWindow.state(from: []) == .gone, "no entry: closed or quit")
        let away: [String: Any] = [kCGWindowNumber as String: 4, kCGWindowBounds as String: bounds.dictionaryRepresentation]
        #expect(SystemSettingsWindow.state(from: [away]) == .offScreen, "no on-screen mark: minimized, hidden or another Space")
        var shown = away
        shown[kCGWindowIsOnscreen as String] = true
        #expect(SystemSettingsWindow.state(from: [shown]) == .onScreen(bounds))
    }

    @Test func theDragLineBoldsTheHelperAndTheGrant() {
        let line = HelperDragPanel.dragLine(helper: "cmux Computer Use", grant: "Screenshots")
        let text = line.string as NSString
        let bold = Typography.system(size: TypeScale.body, weight: TypeScale.emphasis).fontName
        for name in ["cmux Computer Use", "Screenshots"] {
            let font = line.attribute(.font, at: text.range(of: name).location, effectiveRange: nil) as? NSFont
            #expect(font?.fontName == bold, "\(name) is bold")
        }
        let start = line.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(start?.fontName != bold)
    }

    @Test func backClosesThePanelAndBringsTheWindowBack() async {
        let (source, model) = make()
        defer { model.stop() }
        await settle(model) { true }
        model.dismissHelper()
        #expect(model.comebacks == 0, "no panel, nothing to come back from")
        model.allow(.screenRecording)
        #expect(model.helping == .screenRecording)
        model.dismissHelper()
        #expect(model.helping == nil, "the panel goes")
        #expect(model.comebacks == 1, "the window comes back to the front")
        #expect(source.opened == [.screenRecording])
    }

    private func makePanel(onBack: @escaping () -> Void = {}) -> HelperDragPanel {
        HelperDragPanel(appURL: URL(fileURLWithPath: "/Applications/cmux Computer Use.app"),
                        pane: .screenRecording, onBack: onBack, onDrop: {})
    }

    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }

    @Test func thePanelHasABackButtonAndNoCloseButton() {
        let backs = Log()
        let panel = makePanel { backs.count += 1 }
        defer { panel.orderOut(nil) }
        let all = buttons(in: panel.contentView)
        #expect(all.count == 1, "one button: back")
        #expect(all.first === panel.back)
        #expect(panel.back.accessibilityLabel() == OnboardingStrings.back)
        panel.back.performClick(nil)
        #expect(backs.count == 1, "back runs the panel's way back")
    }

    @Test func thePanelNamesTheHelperAndTheGrant() {
        let panel = makePanel()
        defer { panel.orderOut(nil) }
        let text = panel.line.attributedStringValue.string
        #expect(text.contains("cmux Computer Use"))
        #expect(text.contains(OnboardingStrings.computerUseName(.screenRecording)))
        #expect(panel.frame.width == HelperDragPanel.width)
    }

    @Test func theArrowStaysStillWithMotionOff() {
        let arrow = HelperPanelArrow()
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = true
        arrow.bounce(true)
        #expect(!arrow.isBouncing, "Reduce Motion: no bob")
        Motion.reduceMotionOverride = false
        arrow.bounce(true)
        #expect(arrow.isBouncing == Motion.indicators.animatesLoops, "the bob follows the indicators gate")
        arrow.bounce(false)
        #expect(!arrow.isBouncing)
    }

    // MARK: Following the System Settings window

    /// The window list, answered by the test. A held read or lookup waits for ``release()``.
    @MainActor private final class FakeSettingsReader: SettingsWindowReading {
        var match: SettingsWindowMatch?
        var state: SettingsWindowState = .gone
        var holdReads = false
        var holdFinds = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func find() async -> SettingsWindowMatch? {
            if holdFinds { await withCheckedContinuation { waiting.append($0) } }
            return match
        }

        func read(_ id: CGWindowID) async -> SettingsWindowState {
            if holdReads { await withCheckedContinuation { waiting.append($0) } }
            return state
        }

        func release() {
            holdReads = false
            holdFinds = false
            let resumed = waiting
            waiting = []
            for continuation in resumed { continuation.resume() }
        }
    }

    /// Where the pane's first list ends, answered by the test (nil: no source, as without the grant).
    @MainActor private final class FakeListReader: SettingsListReading {
        var bottom: CGFloat?
        var reads: [SettingsWindowMatch] = []

        func firstListBottom(in window: SettingsWindowMatch) async -> CGFloat? {
            reads.append(window)
            return bottom
        }
    }

    /// Ticks only when the test calls ``onTick``; keeps the rate asked for.
    @MainActor private final class FakeFollowPace: SettingsFollowPace {
        var onTick: (() -> Void)?
        var rate: SettingsFollowRate?
        func run(_ rate: SettingsFollowRate) { self.rate = rate }
        func stop() { rate = nil }
    }

    @MainActor private final class TestTime {
        var now: TimeInterval = 100
    }

    @MainActor private final class Events {
        var items: [SystemSettingsFollower.Event] = []
    }

    private let settingsBounds = CGRect(x: 100, y: 100, width: 723, height: 625)

    /// One paced tick and the read it starts.
    private func tick(_ follower: SystemSettingsFollower, _ pace: FakeFollowPace) async {
        pace.onTick?()
        await follower.reading?.value
    }

    /// A panel docked to window 7 at ``settingsBounds`` (never shown, so the dock lands at once).
    private func dockedPanel(_ pane: ComputerUsePermissionPane = .screenRecording, list: FakeListReader? = nil,
                             time: TestTime = TestTime()) async -> (HelperDragPanel, FakeSettingsReader, FakeFollowPace, NSScreen?) {
        let reader = FakeSettingsReader(), pace = FakeFollowPace()
        let follower = SystemSettingsFollower(reader: reader, pace: pace, list: list, now: { time.now })
        let panel = HelperDragPanel(appURL: URL(fileURLWithPath: "/Applications/cmux Computer Use.app"),
                                    pane: pane, onBack: {}, onDrop: {}, follower: follower)
        reader.match = SettingsWindowMatch(id: 7, bounds: settingsBounds, pid: 42)
        reader.state = .onScreen(settingsBounds)
        let screen = NSScreen.screens.first
        panel.beginDocking(on: screen)
        await panel.locating?.value
        return (panel, reader, pace, screen)
    }

    @Test func aMovedWindowMovesThePanelAndAStillOneSetsNoFrame() async {
        let (panel, reader, pace, _) = await dockedPanel()
        defer { panel.orderOut(nil) }
        #expect(panel.follower.windowID == 7)
        #expect(panel.frame == panel.dockedFrame(for: settingsBounds))
        #expect(pace.rate == .display)

        await tick(panel.follower, pace)
        #expect(panel.followMoves == 0, "a still window sets no frame")

        let moved = settingsBounds.offsetBy(dx: 60, dy: 40)
        reader.state = .onScreen(moved)
        await tick(panel.follower, pace)
        #expect(panel.followMoves == 1)
        #expect(panel.frame == panel.dockedFrame(for: moved), "the panel stays docked to the moved window")
        await tick(panel.follower, pace)
        #expect(panel.followMoves == 1, "no frame set while the window holds still")
    }

    /// Points from the top of the System Settings window at `bounds` down to the panel's top.
    private func panelTop(_ panel: HelperDragPanel, under bounds: CGRect) -> CGFloat? {
        guard let primary = NSScreen.screens.first else { return nil }
        return SystemSettingsWindow.appKitFrame(bounds, primaryHeight: primary.frame.height).maxY - panel.frame.maxY
    }

    @Test func screenshotsDocksUnderTheFirstList() async {
        let list = FakeListReader()
        list.bottom = 300
        let (panel, _, _, _) = await dockedPanel(list: list)
        defer { panel.orderOut(nil) }
        #expect(list.reads == [SettingsWindowMatch(id: 7, bounds: settingsBounds, pid: 42)], "one read before the first frame")
        #expect(panel.listBottom == 300)
        #expect(panelTop(panel, under: settingsBounds) == 300 + SystemSettingsWindow.listGap,
                "the panel's top is a small gap under the first list")
        #expect(panel.frame == panel.dockedFrame(for: settingsBounds))
    }

    /// With no read of the list, a guess covered its rows (seen 2026-10-28 with six apps): dock at the bottom.
    @Test func screenshotsWithoutASourceDocksAtTheBottom() async {
        let list = FakeListReader()
        let (panel, _, _, _) = await dockedPanel(list: list)
        defer { panel.orderOut(nil) }
        #expect(list.reads.count == 1)
        #expect(panel.listBottom == nil)
        #expect(panel.frame == panel.dockedFrame(for: settingsBounds))
        let (accessibility, _, _, _) = await dockedPanel(.accessibility)
        defer { accessibility.orderOut(nil) }
        #expect(panel.frame.minY == accessibility.frame.minY, "the same bottom docking as the Accessibility panel")
        let (bare, _, _, _) = await dockedPanel()
        defer { bare.orderOut(nil) }
        #expect(bare.listBottom == nil, "no list reader: the bottom too")
    }

    @Test func accessibilityStillDocksAtTheBottom() async {
        let (panel, _, _, screen) = await dockedPanel(.accessibility)
        defer { panel.orderOut(nil) }
        #expect(panel.listBottom == nil)
        guard let primary = NSScreen.screens.first else { return }
        let settings = SystemSettingsWindow.appKitFrame(settingsBounds, primaryHeight: primary.frame.height)
        let bottom = SystemSettingsWindow.dockedFrame(panel: panel.frame.size, iconCenter: HelperDragPanel.iconCenter,
                                                      settings: settings, visible: screen?.visibleFrame)
        #expect(panel.frame == bottom)
    }

    @Test func followingKeepsThePanelUnderTheList() async {
        let list = FakeListReader(), time = TestTime()
        list.bottom = 300
        let (panel, reader, pace, _) = await dockedPanel(list: list, time: time)
        defer { panel.orderOut(nil) }
        let gap = SystemSettingsWindow.listGap
        let moved = settingsBounds.offsetBy(dx: 60, dy: 40)
        reader.state = .onScreen(moved)
        await tick(panel.follower, pace)
        #expect(panel.followMoves == 1)
        #expect(panelTop(panel, under: moved) == 300 + gap, "a move keeps the panel under the list")
        #expect(panel.follower.listReads == 0, "no list read while the window moves")

        // Still: the slow reads read the list again (a scroll, or a new app), at most every listInterval.
        list.bottom = 340
        time.now += SystemSettingsFollower.stillAfter
        await tick(panel.follower, pace)
        #expect(pace.rate == .still)
        #expect(panel.follower.listReads == 1)
        await panel.follower.listReading?.value
        #expect(list.reads.last == SettingsWindowMatch(id: 7, bounds: moved, pid: 42))
        #expect(panelTop(panel, under: moved) == 340 + gap, "the panel moves with the list")
        #expect(panel.followMoves == 2)
        await tick(panel.follower, pace)
        #expect(panel.follower.listReads == 1, "no second read within listInterval")

        // A failed read keeps the last place.
        list.bottom = nil
        time.now += SystemSettingsFollower.listInterval
        await tick(panel.follower, pace)
        await panel.follower.listReading?.value
        #expect(panel.follower.listReads == 2)
        #expect(panelTop(panel, under: moved) == 340 + gap)
    }

    @Test func anOffScreenWindowHidesThePanelUntilItIsBack() async {
        let (panel, reader, pace, _) = await dockedPanel()
        defer { panel.orderOut(nil) }
        reader.state = .offScreen
        await tick(panel.follower, pace)
        #expect(panel.isAway)
        #expect(!panel.isVisible)
        #expect(pace.rate == .still, "slow reads until the window is back")
        await tick(panel.follower, pace)
        #expect(panel.isAway)

        let back = settingsBounds.offsetBy(dx: 30, dy: 0)
        reader.state = .onScreen(back)
        await tick(panel.follower, pace)
        #expect(!panel.isAway)
        #expect(panel.isVisible, "the panel comes back with the window")
        #expect(panel.frame == panel.dockedFrame(for: back))
        #expect(pace.rate == .display)
    }

    @Test func aClosedWindowSendsThePanelToItsFallbackAndTheLookupResumes() async {
        let (panel, reader, pace, screen) = await dockedPanel()
        defer { panel.orderOut(nil) }
        reader.state = .gone
        reader.match = nil
        reader.holdFinds = true
        await tick(panel.follower, pace)
        #expect(panel.follower.windowID == nil)
        #expect(pace.rate == nil, "no reads of a closed window")
        if let visible = screen?.visibleFrame {
            #expect(panel.frame == SystemSettingsWindow.fallbackFrame(panel: panel.frame.size, visible: visible))
        }
        let lookup = panel.locating
        #expect(lookup != nil, "the panel looks for a new System Settings window")

        let next = CGRect(x: 200, y: 120, width: 723, height: 625)
        reader.match = SettingsWindowMatch(id: 9, bounds: next)
        reader.release()
        await lookup?.value
        #expect(panel.follower.windowID == 9)
        #expect(panel.frame == panel.dockedFrame(for: next))
        #expect(pace.rate == .display)
    }

    @Test func onlyOneReadIsInFlight() async {
        let reader = FakeSettingsReader(), pace = FakeFollowPace()
        let follower = SystemSettingsFollower(reader: reader, pace: pace)
        follower.follow(SettingsWindowMatch(id: 3, bounds: settingsBounds))
        reader.state = .onScreen(settingsBounds)
        reader.holdReads = true
        pace.onTick?()
        pace.onTick?()
        pace.onTick?()
        #expect(follower.reads == 1, "ticks while a read runs are skipped")
        let read = follower.reading
        reader.release()
        await read?.value
        #expect(follower.reading == nil)
        await tick(follower, pace)
        #expect(follower.reads == 2)
    }

    @Test func theReadsSlowDownWhenTheWindowIsStillAndSpeedUpWhenItMoves() async {
        let reader = FakeSettingsReader(), pace = FakeFollowPace(), time = TestTime(), events = Events()
        let follower = SystemSettingsFollower(reader: reader, pace: pace, now: { time.now })
        follower.onEvent = { events.items.append($0) }
        follower.follow(SettingsWindowMatch(id: 3, bounds: settingsBounds))
        #expect(pace.rate == .display)
        reader.state = .onScreen(settingsBounds)
        time.now += SystemSettingsFollower.stillAfter / 2
        await tick(follower, pace)
        #expect(pace.rate == .display, "still for less than a second: display frames")
        time.now += SystemSettingsFollower.stillAfter
        await tick(follower, pace)
        #expect(pace.rate == .still, "still for a second: the slow reads")
        #expect(SystemSettingsFollower.stillInterval == .milliseconds(100))
        #expect(events.items.isEmpty, "a still window reports nothing")

        let moved = settingsBounds.offsetBy(dx: 5, dy: 0)
        reader.state = .onScreen(moved)
        await tick(follower, pace)
        #expect(pace.rate == .display, "a move goes back to display frames")
        #expect(events.items == [.dock(moved)])
    }

    @Test func followingStopsWhenThePanelCloses() async {
        let (panel, reader, pace, _) = await dockedPanel()
        reader.holdReads = true
        pace.onTick?()
        let read = panel.follower.reading
        panel.orderOut(nil)
        #expect(pace.rate == nil, "no frames or deadlines once the panel closes")
        #expect(panel.follower.windowID == nil)
        #expect(panel.follower.reading == nil)
        reader.state = .onScreen(settingsBounds.offsetBy(dx: 80, dy: 0))
        reader.release()
        await read?.value
        #expect(panel.followMoves == 0, "a read that lands after the close moves nothing")
        pace.onTick?()
        #expect(panel.follower.reads == 1, "no read after the close")
    }

    // MARK: The rows' icons

    @Test func aMissingIconFileShowsTheGrantSymbol() async {
        let symbol = ComputerUseGrantIcon.symbol(.accessibility)
        let look = await ComputerUseGrantIcon.look(paths: ["/nonexistent/cmux-missing-grant-icon.appex"], symbol: symbol)
        guard case .symbol(let name) = look else {
            Issue.record("a missing icon file gives the SF Symbol")
            return
        }
        #expect(name == symbol)
        for pane in ComputerUsePermissionPane.allCases {
            #expect(NSImage(systemSymbolName: ComputerUseGrantIcon.symbol(pane), accessibilityDescription: nil) != nil,
                    "\(pane) falls back to a real SF Symbol")
        }
    }

    /// The Screenshot app's icon is an opaque white tile; the row draws the bare symbol instead.
    @Test func screenshotsUsesTheBareSymbol() async {
        #expect(ComputerUseGrantIcon.paths(.screenRecording).isEmpty)
        let look = await ComputerUseGrantIcon.look(paths: ComputerUseGrantIcon.paths(.screenRecording),
                                                   symbol: ComputerUseGrantIcon.symbol(.screenRecording))
        guard case .symbol(let name) = look else {
            Issue.record("Screenshots shows its symbol")
            return
        }
        #expect(name == "camera.viewfinder")
    }
}
