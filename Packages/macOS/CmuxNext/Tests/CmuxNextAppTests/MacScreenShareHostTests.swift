@testable import CmuxNextMacScreen
import Foundation
import Testing

/// Mac Screen's grants are cmux Computer Use's, read and requested through its host; failed
/// reads must not leave a prior grant visible, and nothing is ever asked for the app itself.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct MacScreenShareHostTests {
    private static func helper(_ read: @escaping @Sendable () async throws -> (screen: Bool, control: Bool, holder: String?),
                               requests: AsyncStream<Bool>.Continuation? = nil) -> MacScreenHelperPermissions {
        MacScreenHelperPermissions(read: read, request: { requests?.yield($0) })
    }

    @Test func aFreshReadReplacesCachedDenial() async {
        let host = MacScreenShareHost()
        host.helper = Self.helper { (false, false, "cmux Computer Use") }
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)

        host.helper = Self.helper { (true, true, "cmux Computer Use") }
        await host.refreshPermissions()
        #expect(host.screenRecordingGranted)
        #expect(host.accessibilityGranted)
        #expect(host.grantHolderName == "cmux Computer Use")
    }

    @Test func aFailedReadClearsAnEarlierGrant() async {
        let host = MacScreenShareHost()
        host.helper = Self.helper { (true, true, "cmux Computer Use") }
        await host.refreshPermissions()
        host.helper = Self.helper { throw CocoaError(.fileNoSuchFile) }
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)
        #expect(!host.accessibilityGranted)
        #expect(host.grantHolderName == nil)
    }

    /// Without the helper host nothing is granted and nothing is asked (no in-app fallback).
    @Test func withoutTheHelperNothingIsGrantedOrRequested() async {
        let host = MacScreenShareHost()
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)
        #expect(!host.accessibilityGranted)
        #expect(host.grantHolderName == nil)
        host.requestScreenRecording()
        host.requestAccessibility()
    }

    @Test func requestsGoToTheHelperHost() async throws {
        let host = MacScreenShareHost()
        let (asked, requests) = AsyncStream.makeStream(of: Bool.self)
        host.helper = Self.helper({ (false, false, "cmux Computer Use") }, requests: requests)
        host.requestScreenRecording()
        host.requestAccessibility()
        var seen: Set<Bool> = []
        for await screenRecording in asked {
            seen.insert(screenRecording)
            if seen.count == 2 { break }
        }
        #expect(seen == [true, false])
    }

    @Test func aLaterReadWinsOverAnOlderOneThatEndsAfterIt() async {
        let host = MacScreenShareHost()
        let (entered, enter) = AsyncStream.makeStream(of: Void.self)
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        host.helper = Self.helper {
            enter.yield()
            var waiting = released.makeAsyncIterator()
            _ = await waiting.next()
            return (true, true, nil)
        }
        let older = Task { await host.refreshPermissions() }
        var waiting = entered.makeAsyncIterator()
        _ = await waiting.next()
        host.helper = Self.helper { (false, true, nil) }
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)
        release.yield()
        release.finish()
        await older.value
        #expect(!host.screenRecordingGranted)
        #expect(host.accessibilityGranted)
    }
}
