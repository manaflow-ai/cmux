import AppKit
import CmuxNextDesign
@testable import CmuxNextOnboarding
import Testing

/// The tool window's page covers the whole window, its titlebar too; a Chromium page is a child
/// window over it, so the page leaves the close button's rect uncovered and the button takes the
/// click, on each of the three tool windows. The page sits in a title row host, so a press on its
/// row background moves the window. The window stays transparent until the page paints or the
/// reveal limit passes, so it never shows empty glass with the page popping in.
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

    @Test(arguments: [OnboardingModel.Step.agents, .importData, .computerUse])
    func aPressOnThePagesTitleRowMovesTheWindow(_ step: OnboardingModel.Step) throws {
        let controller = OnboardingWindowController(model: OnboardingModel(services: MockOnboardingServices(), step: step), activeLook: nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let page = try #require(controller.pageView)
        window.layoutIfNeeded()
        let top = CGPoint(x: window.frame.width / 2, y: window.frame.height - 8)
        #expect(TitleRowHostView.takesTitleRowPress(from: page, atWindowPoint: top), "the page's title row moves the window")
        let middle = CGPoint(x: window.frame.width / 2, y: window.frame.height / 2)
        #expect(!TitleRowHostView.takesTitleRowPress(from: page, atWindowPoint: middle), "the body does not")
    }

    @Test func theWindowStaysTransparentUntilThePagePaintsOrTheLimitPasses() async throws {
        let controller = OnboardingWindowController(model: OnboardingModel(services: MockOnboardingServices(), step: .agents), activeLook: nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        controller.present()
        #expect(window.alphaValue == 0, "no empty glass before the page's first frame")
        let deadline = ContinuousClock.now + OnboardingWindowController.revealLimit + .seconds(2)
        while window.alphaValue < 1, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(window.alphaValue == 1, "shown once the page paints, or at the limit")
    }
}
