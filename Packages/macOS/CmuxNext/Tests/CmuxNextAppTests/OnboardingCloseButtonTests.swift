import AppKit
@testable import CmuxNextOnboarding
import Testing

/// The tool window's page covers the whole window, its titlebar too; a Chromium page is a child
/// window over it, so the page leaves the close button's rect uncovered and the button takes the
/// click, on each of the three tool windows.
@MainActor @Suite struct OnboardingCloseButtonTests {
    @Test(arguments: [OnboardingModel.Step.agents, .importData, .computerUse])
    func thePageLeavesTheCloseButtonUncovered(_ step: OnboardingModel.Step) throws {
        let controller = OnboardingWindowController(model: OnboardingModel(services: MockOnboardingServices(), step: step), activeLook: nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let button = try #require(window.standardWindowButton(.closeButton))
        let titlebar = try #require(button.superview)
        window.layoutIfNeeded()
        controller.leaveCloseButtonUncovered()
        let rects = controller.uncoveredRects
        try #require(rects.count == 1, "only the close button: \(rects)")
        let center = titlebar.convert(CGPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
        #expect(!button.frame.isEmpty)
        #expect(rects[0].contains(center), "the rect is where the button is: \(rects[0]) for \(center)")
        #expect(rects[0].width >= button.frame.width && rects[0].height >= button.frame.height, "the whole button: \(rects[0])")
    }
}
