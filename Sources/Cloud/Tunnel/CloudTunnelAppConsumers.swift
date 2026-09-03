import Foundation

struct CloudTunnelAppConsumers: CloudTunnelConsumerSource {
    let cloudWorkspaceCount: @MainActor @Sendable () -> Int
    let connectedLinkCount: @Sendable () async -> Int

    func liveConsumerCount() async -> Int {
        let workspaces = await cloudWorkspaceCount()
        let links = await connectedLinkCount()
        return workspaces + links
    }
}
