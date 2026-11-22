import CoreGraphics
import Testing
@testable import CmuxNextDesign

/// Every window opens on its parent shell window's screen, or on the agent
/// test screen when one is set; never on a display the user did not open
/// it from.
@MainActor
struct WindowPlacementTests {
    /// Main display (menu bar) left, secondary display right.
    private let main = CGRect(x: 0, y: 0, width: 2560, height: 1415)
    private let secondary = CGRect(x: 2560, y: -300, width: 1728, height: 1085)

    @Test func screenFollowsTheParentUnlessATestScreenIsSet() {
        #expect(WindowPlacement.screenIndex(test: nil, parent: 1, count: 2) == 1)
        #expect(WindowPlacement.screenIndex(test: nil, parent: 0, count: 2) == 0)
        #expect(WindowPlacement.screenIndex(test: .last, parent: 0, count: 2) == 1)
        #expect(WindowPlacement.screenIndex(test: .index(0), parent: 1, count: 2) == 0)
        #expect(WindowPlacement.screenIndex(test: .index(7), parent: 0, count: 2) == 1)
        #expect(WindowPlacement.screenIndex(test: nil, parent: nil, count: 2) == nil)
        #expect(WindowPlacement.screenIndex(test: .last, parent: nil, count: 0) == nil)
    }

    @Test func auxiliaryWindowCentersOverItsParentOnTheParentsScreen() {
        let parent = CGRect(x: 2874, y: -100, width: 1100, height: 720)
        let frame = WindowPlacement.frame(size: CGSize(width: 460, height: 520), parentFrame: parent, visible: secondary)
        #expect(secondary.contains(frame))
        #expect(frame.midX == parent.midX)
        #expect(frame.midY == parent.midY)
        #expect(!main.intersects(frame))
    }

    @Test func frameStaysInsideTheVisibleFrame() {
        // Parent hugging the right edge: the window shifts left, never off screen.
        let parent = CGRect(x: 3900, y: 0, width: 400, height: 300)
        let frame = WindowPlacement.frame(size: CGSize(width: 900, height: 2000), parentFrame: parent, visible: secondary)
        #expect(secondary.contains(frame))
        #expect(frame.height == secondary.height)
    }

    @Test func parentOnAnotherScreenCentersOnTheTargetScreen() {
        // Test screen differs from the parent's screen: center on the test screen.
        let parent = CGRect(x: 100, y: 100, width: 1100, height: 720)
        let frame = WindowPlacement.frame(size: CGSize(width: 440, height: 452), parentFrame: parent, visible: secondary)
        #expect(frame.midX == secondary.midX)
        #expect(secondary.contains(frame))
    }

    @Test func cascadeMovesRightAndDown() {
        let a = WindowPlacement.frame(size: CGSize(width: 400, height: 300), parentFrame: nil, visible: main)
        let b = WindowPlacement.frame(size: CGSize(width: 400, height: 300), parentFrame: nil, visible: main, cascade: 1)
        #expect(b.minX == a.minX + WindowPlacement.cascadeStep)
        #expect(b.minY == a.minY - WindowPlacement.cascadeStep)
    }
}
