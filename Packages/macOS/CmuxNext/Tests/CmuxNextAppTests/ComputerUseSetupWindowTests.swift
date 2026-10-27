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
/// that open it, and where the drag panel docks.
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

    @Test func thePanelDocksOverTheBottomOfSystemSettings() {
        let size = NSSize(width: HelperDragPanel.width, height: 100)
        let settings = NSRect(x: 100, y: 200, width: 900, height: 600)
        let docked = SystemSettingsWindow.dockedFrame(panel: size, settings: settings, visible: nil)
        #expect(docked.maxX == settings.maxX - SystemSettingsWindow.inset)
        #expect(docked.minY == settings.minY + SystemSettingsWindow.inset)
        // Too narrow to clear the sidebar: centered instead.
        let narrow = NSRect(x: 100, y: 200, width: 500, height: 600)
        #expect(SystemSettingsWindow.dockedFrame(panel: size, settings: narrow, visible: nil).midX == narrow.midX)
        // Kept on screen.
        let visible = NSRect(x: 0, y: 40, width: 1440, height: 860)
        let low = NSRect(x: 1000, y: 0, width: 700, height: 500)
        let kept = SystemSettingsWindow.dockedFrame(panel: size, settings: low, visible: visible)
        #expect(visible.contains(kept))
    }

    @Test func theWindowListPicksTheFrontmostSettingsWindow() {
        let list: [[String: Any]] = [
            [kCGWindowOwnerName as String: "System Settings", kCGWindowLayer as String: 0,
             kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 40, height: 40).dictionaryRepresentation],
            [kCGWindowOwnerName as String: "Finder", kCGWindowLayer as String: 0,
             kCGWindowBounds as String: CGRect(x: 10, y: 10, width: 800, height: 600).dictionaryRepresentation],
            [kCGWindowOwnerName as String: "System Settings", kCGWindowLayer as String: 25,
             kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 800, height: 600).dictionaryRepresentation],
            [kCGWindowOwnerName as String: "System Settings", kCGWindowLayer as String: 0,
             kCGWindowBounds as String: CGRect(x: 50, y: 60, width: 800, height: 600).dictionaryRepresentation],
        ]
        let bounds = SystemSettingsWindow.pick(list, owners: SystemSettingsWindow.ownerNames())
        #expect(bounds == CGRect(x: 50, y: 60, width: 800, height: 600))
        let frame = SystemSettingsWindow.appKitFrame(CGRect(x: 50, y: 60, width: 800, height: 600), primaryHeight: 1000)
        #expect(frame == NSRect(x: 50, y: 340, width: 800, height: 600))
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
}
