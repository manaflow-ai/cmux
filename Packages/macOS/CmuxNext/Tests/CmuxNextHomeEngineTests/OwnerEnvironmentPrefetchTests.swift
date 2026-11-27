@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The Chief owner's brains value (acpmux's signature check) starts with the owner's run task and is built
/// once, so the spawn's environment waits only for what is left of it.
@Suite struct OwnerEnvironmentPrefetchTests {
    private actor Counter {
        var count = 0
        func bump() { count += 1 }
    }

    @Test func nothingRunsUntilItIsStarted() async {
        let counter = Counter()
        let prefetch = OwnerEnvironmentPrefetch { await counter.bump(); return "{}" }
        #expect(await counter.count == 0)
        #expect(await !prefetch.isStarted)
    }

    @Test func beginningEarlyBuildsOnceAndValueAwaitsIt() async {
        let counter = Counter()
        let prefetch = OwnerEnvironmentPrefetch {
            await counter.bump()
            try? await Task.sleep(for: .milliseconds(50))
            return "{\"executable\":\"/x\"}"
        }
        await prefetch.begin()
        await prefetch.begin()
        #expect(await prefetch.value() == "{\"executable\":\"/x\"}")
        #expect(await prefetch.value() == "{\"executable\":\"/x\"}")
        #expect(await counter.count == 1)
    }

    @Test func valueStartsItWhenNoOneBegan() async {
        let prefetch = OwnerEnvironmentPrefetch { nil }
        #expect(await prefetch.value() == nil)
        #expect(await prefetch.isStarted)
    }

    @Test func theSpawnEnvironmentKeepsTheBrainsValueAndRecordsTheSpace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prefetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = ChiefHome(root: root, isolated: false, buildID: "com.cmuxterm.app.debug.my-tag")
        let environment = ChiefConversationOwner.ownerEnvironment(home: home, process: ["CMUX_BUILD_SPACE": "dev:my-tag"],
                                                                  brains: "{\"home\":\"/h\"}")
        #expect(environment["CMUX_TUI_CHIEF_BRAINS"] == "{\"home\":\"/h\"}")
        #expect(environment["CMUX_TUI_CHIEF_TOOLS_SOCKET"]?.hasSuffix("optchat/tools.sock") == true)
        #expect(environment["CMUX_BUILD_SPACE"] == "dev:my-tag")
    }
}
