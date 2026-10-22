@testable import CmuxNextApp
import CmuxNextApps
import Foundation
import Testing

/// A daemon from before a family existed refuses the whole registration
/// (`bad-request`: "memory is not a provider family"); the channel registers
/// again without the newer families so the older ones keep working.
@MainActor
struct AppsProviderChannelNewerFamilyTests {
    private struct Owner: AppHostCapabilityHandler {
        let families: Set<String>
        func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON { .null }
    }

    @Test func anOlderDaemonKeepsTheFamiliesItKnows() async {
        let (attempts, sink) = AsyncStream.makeStream(of: [String].self)
        let connection = NSObject()
        let link = AppsProviderLink(connection: { connection }, register: { _, families in
            sink.yield(families)
            return families.contains("memory") ? "bad-request" : nil
        }, answer: { _, _, _, _ in })
        let channel = AppsProviderChannel(link: link)
        channel.attach(AppHostCapabilities([Owner(families: ["coderouter", "agent_cli"]), Owner(families: ["memory"])]))
        channel.connectionChanged(epoch: 1)
        var seen: [[String]] = []
        for await families in attempts {
            seen.append(families)
            if seen.count == 2 { break }
        }
        #expect(seen == [["agent_cli", "coderouter", "memory"], ["agent_cli", "coderouter"]])
    }

    @Test func aCurrentDaemonRegistersEveryFamilyOnce() async {
        let (attempts, sink) = AsyncStream.makeStream(of: [String].self)
        let connection = NSObject()
        let link = AppsProviderLink(connection: { connection }, register: { _, families in
            sink.yield(families)
            sink.finish()
            return nil
        }, answer: { _, _, _, _ in })
        let channel = AppsProviderChannel(link: link)
        channel.attach(AppHostCapabilities([Owner(families: ["coderouter"]), Owner(families: ["memory"])]))
        channel.connectionChanged(epoch: 1)
        var seen: [[String]] = []
        for await families in attempts { seen.append(families) }
        #expect(seen == [["coderouter", "memory"]])
    }
}
