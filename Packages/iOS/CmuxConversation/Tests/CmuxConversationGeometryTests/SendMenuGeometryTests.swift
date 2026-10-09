import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

/// Frames recorded from MobileSMS on an iPhone 17 Pro (402 x 874 pt, safe
/// area 62 top / 34 bottom) in the iOS 26.5 and 27.0 simulators.
@Suite struct SendMenuGeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 402, height: 874)
    let safe: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) = (62, 0, 34, 0)

    @Test func longMenuShowsSixAndAHalfRows() {
        #expect(abs(SendMenuGeometry.height(itemCount: 9) - 456.6) < 0.001)
    }

    @Test func openAboveTheHomeIndicatorMatchesMessages() {
        // iOS 26.5: "+" at {28, 806, 40, 40}; popover {10, 373, 320, 456.6}.
        let frame = SendMenuGeometry.openFrame(anchor: CGRect(x: 28, y: 806, width: 40, height: 40), in: screen, safeArea: safe, itemCount: 9)
        #expect(frame.origin == CGPoint(x: 10, y: 373))
        #expect(frame.width == 320)
    }

    @Test func openCenteredOnARaisedPlusMatchesMessages() {
        // iOS 27.0 with the keyboard up: "+" at {16, 490, 40, 40}; popover {10, 281, 320, 456.6}.
        let frame = SendMenuGeometry.openFrame(anchor: CGRect(x: 16, y: 490, width: 40, height: 40), in: screen, safeArea: safe, itemCount: 9)
        #expect(frame.origin == CGPoint(x: 10, y: 281))
    }

    @Test func shortMenuFitsItsRows() {
        #expect(SendMenuGeometry.height(itemCount: 4) == CGFloat(21 + 4 * 66 + 21))
    }

    @Test func dragShrinksTowardThePlusButton() {
        let open = CGRect(x: 10, y: 373, width: 320, height: 456.6)
        let plus = CGRect(x: 28, y: 806, width: 40, height: 40)
        #expect(SendMenuGeometry.draggedFrame(open: open, anchor: plus, translation: 0) == open)
        let dragged = SendMenuGeometry.draggedFrame(open: open, anchor: plus, translation: 306)
        #expect(abs(dragged.width - 180) < 0.5)
        #expect(SendMenuGeometry.dragProgress(translation: -40) == 0)
    }

    @Test func springsMatchChatKitImplicitDurations() {
        // UIKit's implicit durations printed beside the ChatKit animators.
        #expect(abs(SendMenuGeometry.Present.horizontal.dampingRatio - 0.7348469) < 1e-6)
        #expect(abs(SendMenuGeometry.Present.vertical.dampingRatio - 0.6917482) < 1e-6)
        #expect(abs(SendMenuGeometry.Dismiss.vertical.dampingRatio - 0.9593835) < 1e-6)
    }
}

@Suite struct SendMenuSpringTests {
    @Test func underdampedSpringOvershootsByTheTextbookAmount() {
        let spring = SendMenuGeometry.Present.horizontal
        // Peak at pi / omega_d: overshoot exp(-pi zeta / sqrt(1 - zeta^2)), 3.3% for zeta 0.735.
        let omega = (spring.stiffness / spring.mass).squareRoot()
        let zeta = spring.dampingRatio
        let peak = Double(CGFloat.pi / (omega * (1 - zeta * zeta).squareRoot()))
        #expect(abs(spring.progress(at: peak) - 1.0334) < 0.001)
        #expect(spring.progress(at: 0) == 0)
        #expect(abs(spring.progress(at: spring.settlingDuration) - 1) < 0.005)
    }

    @Test func overdampedAndCriticalSpringsStartAtRestAndSettle() {
        let over = SendMenuGeometry.Present.content
        #expect(over.dampingRatio > 1)
        #expect(over.progress(at: 0.0001) < 0.001)
        #expect(abs(over.progress(at: over.settlingDuration) - 1) < 0.005)
    }

    @Test func horizontalTracksStartAFewMillisecondsLate() {
        #expect(abs(SendMenuGeometry.Present.horizontal.delay - 0.0212) < 0.0005)
    }
}

@Suite struct SendMenuCornerTests {
    let closed = CGSize(width: 40, height: 40)
    let open = CGSize(width: 320, height: 306)

    @Test func startsAsTheCircleAndEndsWithMenuCorners() {
        #expect(SendMenuGeometry.cornerRadius(for: closed, closed: closed, open: open) == 20)
        #expect(SendMenuGeometry.cornerRadius(for: open, closed: closed, open: open) == SendMenuGeometry.cornerRadius)
    }

    @Test func staysRoundWhileSmall() {
        // A quarter of the way up the menu is still nearly a capsule.
        let size = CGSize(width: 110, height: 106.5)
        let radius = SendMenuGeometry.cornerRadius(for: size, closed: closed, open: open)
        #expect(radius > 45 && radius <= 53.25)
    }
}
