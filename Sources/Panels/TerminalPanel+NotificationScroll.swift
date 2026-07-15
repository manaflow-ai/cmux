import Foundation
import CmuxTerminal

@MainActor
extension TerminalPanel {
    static func prepareNotificationScrollReplay(
        for paneHost: any TerminalSurfacePaneHosting,
        environment: [String: String]
    ) {
        guard let replayPath = environment[SessionScrollbackReplayStore.environmentKey],
              let hostedView = paneHost as? GhosttySurfaceScrollView else {
            return
        }
        hostedView.armSessionScrollbackReplay(
            expectedStartBoundary: SessionScrollbackReplayStore.startBoundaryValue(
                forReplayFilePath: replayPath
            ),
            expectedEndBoundary: SessionScrollbackReplayStore.endBoundaryValue(
                forReplayFilePath: replayPath
            )
        )
    }

    var notificationScrollPosition: TerminalNotificationScrollPosition? {
        hostedView.notificationScrollPosition
    }

    @discardableResult
    func restoreNotificationScrollPosition(_ position: TerminalNotificationScrollPosition?) -> Bool {
        if position == nil { return hostedView.restoreNotificationScrollPosition(nil) }
        guard !isAgentHibernated else { return false }
        return hostedView.restoreNotificationScrollPosition(position)
    }
}
