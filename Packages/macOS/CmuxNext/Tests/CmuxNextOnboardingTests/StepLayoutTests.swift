import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign
import Testing
@testable import CmuxNextOnboarding

/// Each tool's screen lays out in the fixed-size window: Auto Layout finishes (no
/// layout loop) and the window keeps its size.
@MainActor
@Suite struct StepLayoutTests {
    @Test(arguments: OnboardingModel.Step.allCases)
    func stepLaysOutInTheWindow(_ step: OnboardingModel.Step) async {
        let services = MockOnboardingServices()
        services.computerUseSource = MockComputerUsePermissionSource()
        let model = OnboardingModel(services: services, step: step)
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
}
