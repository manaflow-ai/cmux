@testable import CmuxNextMacScreen
import Foundation
import Testing

/// Permission snapshots use a fresh child; failed reads must not leave a prior grant visible.
@MainActor @Suite
struct MacScreenShareHostTests {
    @Test func aFreshReadReplacesCachedDenial() async {
        let host = MacScreenShareHost()
        host.readPermissions = { (false, false) }
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)

        host.readPermissions = { (true, true) }
        await host.refreshPermissions()
        #expect(host.screenRecordingGranted)
        #expect(host.accessibilityGranted)
    }

    @Test func aFailedProbeClearsAnEarlierGrant() async {
        let host = MacScreenShareHost()
        host.readPermissions = { (true, true) }
        await host.refreshPermissions()
        host.readPermissions = { throw CocoaError(.fileNoSuchFile) }
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)
        #expect(!host.accessibilityGranted)
    }

    @Test func aLaterReadWinsOverAnOlderOneThatEndsAfterIt() async {
        let host = MacScreenShareHost()
        let (entered, enter) = AsyncStream.makeStream(of: Void.self)
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        host.readPermissions = {
            enter.yield()
            var waiting = released.makeAsyncIterator()
            _ = await waiting.next()
            return (true, true)
        }
        let older = Task { await host.refreshPermissions() }
        var waiting = entered.makeAsyncIterator()
        _ = await waiting.next()
        host.readPermissions = { (false, true) }
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)
        release.yield()
        release.finish()
        await older.value
        #expect(!host.screenRecordingGranted)
        #expect(host.accessibilityGranted)
    }
}
