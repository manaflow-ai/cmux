import AppKit
import Testing

@testable import CmuxSimulatorUI

@Suite("Remote frame hit testing")
@MainActor
struct CmuxRemoteFrameViewHitTestingTests {
    @Test("Read-only frame presentation leaves pointer input to its host")
    func framePresentationPassesPointerInputToHost() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let frameView = CmuxRemoteFrameView(frame: host.bounds)
        host.addSubview(frameView)

        #expect(host.hitTest(NSPoint(x: 200, y: 150)) === host)
    }

    @Test("Read-only frame presentation leaves background styling to its host")
    func framePresentationUsesTransparentBackground() {
        let frameView = CmuxRemoteFrameView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )

        #expect(frameView.layer?.backgroundColor == NSColor.clear.cgColor)
    }

    @Test("Moving between windows preserves unrelated notifications")
    func windowObservationRemovalIsScoped() {
        let notificationCenter = NotificationCenter.default
        let notificationName = Notification.Name(
            "CmuxRemoteFrameViewHitTestingTests.unrelated"
        )
        let frameView = CmuxRemoteFrameView(frame: .zero)
        CmuxRemoteFrameViewNotificationProbe.receivedCount = 0
        notificationCenter.addObserver(
            frameView,
            selector: #selector(
                CmuxRemoteFrameView.recordUnrelatedTestNotification(_:)
            ),
            name: notificationName,
            object: nil
        )
        defer {
            notificationCenter.removeObserver(frameView)
            frameView.teardown()
        }

        let firstWindow = NSWindow()
        firstWindow.contentView?.addSubview(frameView)
        let secondWindow = NSWindow()
        secondWindow.contentView?.addSubview(frameView)
        notificationCenter.post(name: notificationName, object: nil)

        #expect(CmuxRemoteFrameViewNotificationProbe.receivedCount == 1)
    }
}
