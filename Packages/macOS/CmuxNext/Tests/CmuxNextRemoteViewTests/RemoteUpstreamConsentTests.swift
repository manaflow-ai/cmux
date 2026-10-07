import Foundation
import Testing
@testable import CmuxNextRemoteView

/// The C4b consent contract: nothing is sent without an explicit request, a
/// denied permission or a missing cap means no consent, a sender exists only
/// after `stream_opened`, and stop and session end revoke at once.
struct RemoteUpstreamConsentTests {
    static let caps = ["up_media", "stream.open"]
    static let frame = Data(repeating: 1, count: 120)

    static func make(_ kind: RemoteUpstreamKind, _ stream: UInt16) -> RemoteRdUpstream? {
        RemoteRdUpstream(carrier: .datagram, stream: stream, kind: kind)
    }

    /// Requests `kind` with the permission granted and answers `stream_opened`.
    static func start(_ consent: RemoteUpstreamConsent, _ kind: RemoteUpstreamKind) throws -> RemoteRdUpstream {
        let open = try #require(try consent.request(kind, permissionGranted: true))
        guard case let .started(sender) = consent.opened(stream: open.stream, make: make) else {
            Issue.record("not started")
            throw RemoteRdCoreError.failed
        }
        return sender
    }

    @Test func aNewSenderSendsNothingWithoutConsent() throws {
        let sender = try #require(Self.make(.microphone, 100))
        #expect(throws: RemoteRdCoreError.consent) {
            try sender.send(frame: Self.frame, captureMicros: 0, independent: true, nowMicros: 0)
        }
        #expect(try sender.datagrams().isEmpty)
        #expect(sender.stats().consent == false)
    }

    @Test func aRequestOpensTheStreamTheHostExpects() throws {
        let consent = RemoteUpstreamConsent(welcomeCaps: Self.caps)
        let mic = try #require(try consent.request(.microphone, permissionGranted: true))
        #expect(mic == RemoteRdStreamOpen(stream: 100, kind: .upAudio, codec: "opus"))
        let camera = try #require(try consent.request(.camera, permissionGranted: true))
        #expect(camera == RemoteRdStreamOpen(stream: 101, kind: .upVideo, codec: "h264"))
        #expect(try consent.request(.microphone, permissionGranted: true) == nil, "already requested")
        #expect(consent.requested == [.microphone, .camera])
        #expect(consent.active.isEmpty, "no sender before stream_opened")
    }

    @Test func streamOpenedGrantsThatKindOnly() throws {
        let consent = RemoteUpstreamConsent(welcomeCaps: Self.caps)
        let sender = try Self.start(consent, .microphone)
        #expect(consent.active == [.microphone])
        #expect(sender.stats().consent)
        #expect(try sender.send(frame: Self.frame, captureMicros: 0, independent: true, nowMicros: 0) > 0)
        #expect(try sender.datagrams().count >= 1)
        #expect(consent.sender(.camera) == nil)
        #expect(try consent.request(.microphone, permissionGranted: true) == nil, "already active")
    }

    @Test func aDeniedPermissionAMissingCapOrARefusalGrantsNothing() throws {
        let consent = RemoteUpstreamConsent(welcomeCaps: Self.caps)
        #expect(throws: RemoteUpstreamConsent.Refusal.permissionDenied) {
            _ = try consent.request(.microphone, permissionGranted: false)
        }
        #expect(consent.requested.isEmpty && consent.active.isEmpty)
        for caps in [["stream.open"], ["up_media"], []] {
            let noCap = RemoteUpstreamConsent(welcomeCaps: caps)
            #expect(!noCap.isOffered)
            #expect(throws: RemoteUpstreamConsent.Refusal.notOffered) {
                _ = try noCap.request(.camera, permissionGranted: true)
            }
        }
        let open = try #require(try consent.request(.screen, permissionGranted: true))
        #expect(consent.refused(stream: open.stream) == .screen)
        guard case .ignored = consent.opened(stream: open.stream, make: Self.make) else {
            Issue.record("a refused stream must not start")
            return
        }
        guard case .ignored = consent.opened(stream: 999, make: Self.make) else {
            Issue.record("an unknown stream must not start")
            return
        }
        #expect(consent.active.isEmpty)
    }

    @Test func aSenderTheCoreCannotMakeClosesTheStream() throws {
        let consent = RemoteUpstreamConsent(welcomeCaps: Self.caps)
        let open = try #require(try consent.request(.camera, permissionGranted: true))
        guard case let .failed(stream) = consent.opened(stream: open.stream, make: { _, _ in nil }) else {
            Issue.record("expected failed")
            return
        }
        #expect(stream == open.stream && consent.active.isEmpty)
    }

    @Test func stopRevokesAtOnceAndDropsQueuedDatagrams() throws {
        let consent = RemoteUpstreamConsent(welcomeCaps: Self.caps)
        let sender = try Self.start(consent, .microphone)
        _ = try sender.send(frame: Self.frame, captureMicros: 0, independent: true, nowMicros: 0)
        #expect(consent.stop(.microphone) == sender.stream)
        #expect(consent.active.isEmpty)
        #expect(try sender.datagrams().isEmpty, "revoking drops untaken datagrams")
        #expect(throws: RemoteRdCoreError.consent) {
            try sender.send(frame: Self.frame, captureMicros: 0, independent: true, nowMicros: 1)
        }
        #expect(consent.stop(.microphone) == nil, "nothing left to stop")
        // A request still waiting for the host is forgotten too.
        let open = try #require(try consent.request(.camera, permissionGranted: true))
        #expect(consent.stop(.camera) == open.stream)
        guard case .ignored = consent.opened(stream: open.stream, make: Self.make) else {
            Issue.record("a stopped request must not start")
            return
        }
    }

    @Test func theHostClosingAStreamRevokesIt() throws {
        let consent = RemoteUpstreamConsent(welcomeCaps: Self.caps)
        let sender = try Self.start(consent, .camera)
        #expect(consent.closedByHost(stream: sender.stream) == .camera)
        #expect(consent.active.isEmpty && sender.stats().consent == false)
    }

    @Test func sessionEndRevokesEverythingAndRefusesLaterRequests() throws {
        let consent = RemoteUpstreamConsent(welcomeCaps: Self.caps)
        let mic = try Self.start(consent, .microphone)
        let camera = try Self.start(consent, .camera)
        let screen = try #require(try consent.request(.screen, permissionGranted: true))
        #expect(consent.endSession() == [mic.stream, camera.stream, screen.stream].sorted())
        #expect(consent.active.isEmpty && consent.requested.isEmpty)
        #expect(!mic.stats().consent && !camera.stats().consent)
        #expect(throws: RemoteUpstreamConsent.Refusal.sessionEnded) {
            _ = try consent.request(.microphone, permissionGranted: true)
        }
    }
}
