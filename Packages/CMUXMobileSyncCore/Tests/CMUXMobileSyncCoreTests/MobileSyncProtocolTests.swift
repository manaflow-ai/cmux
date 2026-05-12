import Foundation
import Testing
@testable import CMUXMobileSyncCore

@Test func pairingPayloadRoundTripsThroughURL() throws {
    let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
    let payload = try MobileSyncPairingPayload(
        macDeviceID: "mac-1",
        macDisplayName: "Studio",
        host: "100.64.1.2",
        port: 49831,
        expiresAt: expiresAt,
        transport: .tailscale
    )

    let decoded = try MobileSyncPairingPayload.decodeURL(
        payload.encodedURL(),
        now: Date(timeIntervalSince1970: 1_900_000_000)
    )

    #expect(decoded == payload)
}

@Test func pairingPayloadRejectsLongLivedSecretFields() throws {
    let json = """
    {
      "version": 1,
      "mac_device_id": "mac-1",
      "mac_display_name": "Studio",
      "host": "100.64.1.2",
      "port": 49831,
      "expires_at": "2033-05-18T03:33:20Z",
      "transport": "tailscale",
      "token": "do-not-accept"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    do {
        _ = try decoder.decode(MobileSyncPairingPayload.self, from: Data(json.utf8))
        Issue.record("Expected token-bearing payload to fail")
    } catch let error as MobileSyncPairingPayloadError {
        #expect(error == .forbiddenSecretField("token"))
    }
}

@Test func pairingPayloadRejectsExpiredURLs() throws {
    let payload = try MobileSyncPairingPayload(
        macDeviceID: "mac-1",
        macDisplayName: nil,
        host: "100.64.1.2",
        port: 49831,
        expiresAt: Date(timeIntervalSince1970: 1_000),
        transport: .tailscale
    )

    do {
        _ = try MobileSyncPairingPayload.decodeURL(
            payload.encodedURL(),
            now: Date(timeIntervalSince1970: 1_001)
        )
        Issue.record("Expected expired payload to fail")
    } catch let error as MobileSyncPairingPayloadError {
        #expect(error == .expired)
    }
}

@Test func pairingPayloadSupportsDebugLoopbackWithoutChangingProductionTransport() throws {
    let payload = try MobileSyncPairingPayload(
        macDeviceID: "debug-mac",
        macDisplayName: "Simulator Host",
        host: "127.0.0.1",
        port: 51111,
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        transport: .debugLoopback
    )

    let decoded = try MobileSyncPairingPayload.decodeURL(
        payload.encodedURL(),
        now: Date(timeIntervalSince1970: 1_900_000_000)
    )

    #expect(decoded.transport == .debugLoopback)
    #expect(decoded.host == "127.0.0.1")
}

@Test func frameCodecDecodesCompleteAndPartialFrames() throws {
    let first = try MobileSyncFrameCodec.encodeFrame(Data("one".utf8))
    let second = try MobileSyncFrameCodec.encodeFrame(Data("two".utf8))
    var buffer = Data()
    buffer.append(first)
    buffer.append(second.prefix(5))

    var frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
    #expect(frames == [Data("one".utf8)])
    #expect(buffer == second.prefix(5))

    buffer.append(second.dropFirst(5))
    frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
    #expect(frames == [Data("two".utf8)])
    #expect(buffer.isEmpty)
}

@Test func frameCodecRejectsOversizedFrames() throws {
    var buffer = Data([0x00, 0x00, 0x00, 0x05])
    buffer.append(Data("hello".utf8))

    do {
        _ = try MobileSyncFrameCodec.decodeFrames(from: &buffer, maximumFrameByteCount: 4)
        Issue.record("Expected oversized frame to fail")
    } catch let error as MobileSyncFrameCodecError {
        #expect(error == .frameTooLarge(5))
    }
}
