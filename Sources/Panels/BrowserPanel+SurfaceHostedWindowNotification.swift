import Foundation

extension BrowserPanel {
    func postSurfaceHostedViewDidMoveToWindow() {
        NotificationCenter.default.post(
            name: .surfaceHostedViewDidMoveToWindow,
            object: self,
            userInfo: ["surfaceId": id, "workspaceId": workspaceId]
        )
    }
}
