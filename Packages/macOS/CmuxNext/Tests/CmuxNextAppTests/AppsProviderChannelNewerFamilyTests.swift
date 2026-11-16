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

    /// A daemon that has `memory` but predates `toast` keeps `memory`: only the newest
    /// family it refuses is dropped, one at a time.
    @Test func aDaemonWithMemoryButNoToastKeepsMemory() async {
        let (attempts, sink) = AsyncStream.makeStream(of: [String].self)
        let connection = NSObject()
        let link = AppsProviderLink(connection: { connection }, register: { _, families in
            sink.yield(families)
            if families.contains("toast") { return "bad-request" }
            sink.finish()
            return nil
        }, answer: { _, _, _, _ in })
        let channel = AppsProviderChannel(link: link)
        channel.attach(AppHostCapabilities([Owner(families: ["coderouter"]), Owner(families: ["memory"]), Owner(families: ["toast"])]))
        channel.connectionChanged(epoch: 1)
        var seen: [[String]] = []
        for await families in attempts { seen.append(families) }
        #expect(seen == [["coderouter", "memory", "toast"], ["coderouter", "memory"]])
    }

    /// A daemon that knows `browser.page` but predates `browser.site` keeps `browser.page` and the rest.
    @Test func aDaemonWithoutBrowserSiteKeepsBrowserPage() async {
        let (attempts, sink) = AsyncStream.makeStream(of: [String].self)
        let connection = NSObject()
        let link = AppsProviderLink(connection: { connection }, register: { _, families in
            sink.yield(families)
            if families.contains("browser.site") { return "bad-request" }
            sink.finish()
            return nil
        }, answer: { _, _, _, _ in })
        let channel = AppsProviderChannel(link: link)
        channel.attach(AppHostCapabilities([Owner(families: ["browser.page"]), Owner(families: ["browser.site"]), Owner(families: ["toast"])]))
        channel.connectionChanged(epoch: 1)
        var seen: [[String]] = []
        for await families in attempts { seen.append(families) }
        #expect(seen == [["browser.page", "browser.site", "toast"], ["browser.page", "toast"]])
    }

    /// `apps-site-styles` reaches its handler whether or not the registration has answered yet.
    @Test func aSiteStylesSnapshotIsHandledAtAnyTime() {
        let link = AppsProviderLink(connection: { nil }, register: { _, _ in nil }, answer: { _, _, _, _ in })
        let channel = AppsProviderChannel(link: link)
        var received: [AppJSON] = []
        channel.onSiteStyles = { received.append($0) }
        #expect(channel.handle(name: "apps-site-styles", payload: .object(["styles": .array([])])))
        #expect(received == [["styles": []]])
        #expect(!channel.handle(name: "apps-page-styles", payload: .object([:])), "the old name is not the provider's")
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
