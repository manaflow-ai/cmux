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

    @Test func iOS27SitsOnTheSafeArea() {
        // iOS 27.0: the same "+"; popover {10, 383.3, 320, 456.6}.
        let frame = SendMenuGeometry.openFrame(anchor: CGRect(x: 28, y: 806, width: 40, height: 40), in: screen, safeArea: safe, itemCount: 9, bottomInset: SendMenuGeometry.bottomInset(iOS27: true))
        #expect(frame.origin == CGPoint(x: 10, y: 383))
    }

    @Test func openCenteredOnARaisedPlusMatchesMessages() {
        // iOS 27.0 with the keyboard up: "+" at {16, 490, 40, 40}; popover {10, 281, 320, 456.6}.
        let frame = SendMenuGeometry.openFrame(anchor: CGRect(x: 16, y: 490, width: 40, height: 40), in: screen, safeArea: safe, itemCount: 9)
        #expect(frame.origin == CGPoint(x: 10, y: 281))
    }

    @Test func keyboardUpMenuCentersOnTheRaisedPlusOnBothReleases() {
        // Messages draws the menu over the keyboard, centered on the raised
        // "+": iOS 26.5 "+" {16, 483} -> popover y 274; 27.0 "+" {16, 490} -> y 281.
        let frame26 = SendMenuGeometry.openFrame(anchor: CGRect(x: 16, y: 483, width: 40, height: 40), in: screen, safeArea: safe, itemCount: 9)
        #expect(frame26.origin == CGPoint(x: 10, y: 274))
        let frame27 = SendMenuGeometry.openFrame(anchor: CGRect(x: 16, y: 490, width: 40, height: 40), in: screen, safeArea: safe, itemCount: 9, bottomInset: SendMenuGeometry.bottomInset(iOS27: true))
        #expect(frame27.origin == CGPoint(x: 10, y: 281))
    }

    @Test func cameraPhotosFilesMenuStaysAboveTheKeyboard() {
        // Three rows (Camera, Photos, Files): 21 + 3 x 66 + 21 = 240 pt.
        // iOS 26.5 keyboard up: "+" {16, 483}, keyboard top 535. Centered
        // on the "+" the menu would end at 623, under the keyboard; it ends
        // 10 pt above it instead and still covers the "+" it grew from.
        let plus = CGRect(x: 16, y: 483, width: 40, height: 40)
        let frame = SendMenuGeometry.openFrame(anchor: plus, in: screen, safeArea: safe, itemCount: 3, keyboardTop: 535)
        #expect(frame.height == 240)
        #expect(frame.maxY == 525)
        #expect(frame.minY <= plus.minY && frame.maxY >= plus.maxY)
        // iOS 27.0: "+" {16, 490}, keyboard top 542.
        let frame27 = SendMenuGeometry.openFrame(anchor: CGRect(x: 16, y: 490, width: 40, height: 40), in: screen, safeArea: safe, itemCount: 3, bottomInset: 0, keyboardTop: 542)
        #expect(frame27.maxY == 532)
        // A keyboard low enough leaves the menu centered on the "+".
        let low = SendMenuGeometry.openFrame(anchor: plus, in: screen, safeArea: safe, itemCount: 3, keyboardTop: 700)
        #expect(abs(low.midY - plus.midY) <= 0.5)
        // Keyboard down: the same menu centered on the resting "+" still fits.
        let resting = SendMenuGeometry.openFrame(anchor: CGRect(x: 28, y: 806, width: 40, height: 40), in: screen, safeArea: safe, itemCount: 3)
        #expect(resting.maxY <= screen.maxY - safe.bottom - SendMenuGeometry.edgeInset)
        #expect(resting.maxY > 806)
    }

    @Test func rowArtworkMatchesMessages() {
        // ChatKit's send-menu-*-glass artwork: 54 pt images whose plate is
        // 116 px @3x on iOS 26.5 and 110 px @3x on 27.0.
        #expect(SendMenuGeometry.iconSize == 54)
        #expect(abs(SendMenuGeometry.iconDiscDiameter(iOS27: false) * 3 - 116) < 0.001)
        #expect(abs(SendMenuGeometry.iconDiscDiameter(iOS27: true) * 3 - 110) < 0.001)
        // Icon at x 37 (panel 10 + 27) and the label at x 109, 18.67 pt
        // into its 66 pt row, as in the AX frames.
        #expect(SendMenuGeometry.edgeInset + SendMenuGeometry.iconLeading == 37)
        #expect(SendMenuGeometry.edgeInset + SendMenuGeometry.iconLeading + SendMenuGeometry.iconSize + SendMenuGeometry.iconToLabel == 109)
        #expect(abs((SendMenuGeometry.rowHeight - SendMenuGeometry.labelHeight) / 2 - 18.67) < 0.01)
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

    @Test func springsMatchTheRecordedFrames() {
        // UIKit's implicit durations printed beside the ChatKit animators.
        // Recorded on iOS 27.0 (top edge, per 60 fps frame): 0.475 after 5
        // frames, 0.892 after 10, 0.986 after 13, then ~1% over.
        let open = SendMenuGeometry.Present.vertical
        #expect(abs(open.progress(at: 5.0 / 60) - 0.475) < 0.02)
        #expect(abs(open.progress(at: 10.0 / 60) - 0.892) < 0.02)
        #expect(abs(open.progress(at: 13.0 / 60) - 0.986) < 0.02)
        #expect(abs(open.dampingRatio - 0.81) < 0.005)
        // Back in the "+" (98.6%) after 12 frames.
        #expect(abs(SendMenuGeometry.Dismiss.geometry.progress(at: 12.0 / 60) - 0.986) < 0.02)
    }
}

@Suite struct SendMenuSpringTests {
    @Test func underdampedSpringOvershootsByTheTextbookAmount() {
        let spring = SendMenuGeometry.Spring(mass: 2, stiffness: 300, damping: 36, settlingDuration: 0.8490879)
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
        #expect(abs(SendMenuGeometry.Present.horizontal.delay - 0.025) < 0.0005)
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
