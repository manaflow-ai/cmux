import Foundation

struct CloudTunnelAppConsumers: CloudTunnelConsumerSource {
    let cloudBrowserCount: @MainActor @Sendable () -> Int

    func liveConsumerCount() async -> Int {
        await cloudBrowserCount()
    }
}
