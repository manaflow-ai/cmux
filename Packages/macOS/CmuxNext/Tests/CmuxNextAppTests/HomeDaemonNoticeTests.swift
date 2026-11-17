import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Testing

/// Home says its daemon is too old only once the daemon answered that way. A
/// restore launch showed "Conversations need a newer cmux daemon." from 2012 to
/// 2339 ms while the Chief owner was still connecting (Leo 2026-10-21: "show
/// nothing, or the snapshot, until the daemon actually answers with an old version").
@MainActor
struct HomeDaemonNoticeTests {
    @Test func aTimeoutIsNotARefusal() {
        let services = Self.services()
        // A timeout or a closed socket says nothing about the owner's build.
        services.home.chief.noteFailure(.timedOut("identify"))
        let refusedAfterTimeout = services.home.isRefused
        #expect(!refusedAfterTimeout, "a timeout counted as a refusal")
    }

    @Test func theRefusalOutlivesALaterTimeout() {
        let services = Self.services()
        services.home.chief.noteFailure(.missingCapabilities([DaemonCapability.localConversations.rawValue]))
        let refused = services.home.isRefused
        #expect(refused, "a missing-capabilities refusal was not kept")
        // A later retry that times out keeps the reason up.
        services.home.chief.noteFailure(.timedOut("identify"))
        let refusedAfterRetry = services.home.isRefused
        #expect(refusedAfterRetry, "a timeout after the refusal dropped it")
    }

    @Test func aSuccessfulHandshakeAfterARefusalClearsIt() {
        let services = Self.services()
        services.home.chief.noteFailure(.missingCapabilities([DaemonCapability.localConversations.rawValue]))
        // A newer owner answers; it gets ready (restart check, prepare) before it attaches.
        services.home.chief.noteHandshakeAccepted()
        let refusedAfterAnswer = services.home.isRefused
        #expect(!refusedAfterAnswer, "the old refusal outlived a successful handshake")
    }

    // MARK: Fixtures

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }
}
