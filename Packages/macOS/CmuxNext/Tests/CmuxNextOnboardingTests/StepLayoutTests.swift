import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign
import Testing
@testable import CmuxNextOnboarding

/// Every step lays out in the fixed-size window: Auto Layout finishes (no
/// layout loop) and the window keeps its size.
@MainActor
@Suite struct StepLayoutTests {
    @Test(arguments: OnboardingModel.Step.allCases)
    func stepLaysOutInTheWindow(_ step: OnboardingModel.Step) async {
        let services = MockOnboardingServices()
        services.accountsView = NSView()
        services.firstTaskView = NSView()
        services.computerUseSource = MockComputerUsePermissionSource()
        services.themeChoices = (0..<9).map { ThemeChoice(name: "Theme \($0)", input: .ghosttyDefault) }
        let model = OnboardingModel(services: services, start: step)
        let controller = OnboardingWindowController(model: model)
        guard let window = controller.window else { return }
        // Off every screen, never key: text fields lay out as when visible.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        model.stepDidAppear()
        for _ in 0..<50 { await Task.yield() }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(window.contentView?.frame.size == OnboardingMetrics.windowSize)
        window.close()
    }

    /// Walks every step from the start, as Continue does.
    @Test func walkingTheStepsLaysOut() async {
        let services = MockOnboardingServices()
        services.accountsView = NSView()
        let model = OnboardingModel(services: services)
        let controller = OnboardingWindowController(model: model)
        guard let window = controller.window else { return }
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        model.stepDidAppear()
        for _ in model.steps.dropLast() {
            model.next()
            for _ in 0..<50 { await Task.yield() }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        #expect(model.isLast)
        window.close()
    }
}
