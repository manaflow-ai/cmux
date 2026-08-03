import Foundation

@testable import CmuxSimulatorUI

@MainActor
enum CmuxRemoteFrameViewNotificationProbe {
    static var receivedCount = 0
}

extension CmuxRemoteFrameView {
    @objc func recordUnrelatedTestNotification(_ notification: Notification) {
        CmuxRemoteFrameViewNotificationProbe.receivedCount += 1
    }
}
