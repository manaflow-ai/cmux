import Foundation
import Testing
@testable import CMUXMobileCore

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

@Test func pairingPayloadRejectsSecretFieldNamesContainingToken() throws {
    let json = """
    {
      "version": 1,
      "mac_device_id": "mac-1",
      "mac_display_name": "Studio",
      "host": "100.64.1.2",
      "port": 49831,
      "expires_at": "2033-05-18T03:33:20Z",
      "transport": "tailscale",
      "refreshToken": "do-not-accept"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    do {
        _ = try decoder.decode(MobileSyncPairingPayload.self, from: Data(json.utf8))
        Issue.record("Expected refreshToken-bearing payload to fail")
    } catch let error as MobileSyncPairingPayloadError {
        #expect(error == .forbiddenSecretField("refreshToken"))
    }
}

@Test func pairingPayloadRejectsExpiredURLs() throws {
    let json = """
    {
      "version": 1,
      "mac_device_id": "mac-1",
      "host": "100.64.1.2",
      "port": 49831,
      "expires_at": "1970-01-01T00:16:40Z",
      "transport": "tailscale"
    }
    """
    let url = try #require(URL(string: "cmux-ios://pair?v=1&payload=\(base64URLEncode(Data(json.utf8)))"))

    do {
        _ = try MobileSyncPairingPayload.decodeURL(
            url,
            now: Date(timeIntervalSince1970: 1_001)
        )
        Issue.record("Expected expired payload to fail")
    } catch let error as MobileSyncPairingPayloadError {
        #expect(error == .expired)
    }
}

@Test func pairingPayloadDirectDecodeRejectsExpiredPayloads() throws {
    let json = """
    {
      "version": 1,
      "mac_device_id": "mac-1",
      "host": "100.64.1.2",
      "port": 49831,
      "expires_at": "2001-01-01T00:00:00Z",
      "transport": "tailscale"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    #expect(throws: MobileSyncPairingPayloadError.expired) {
        _ = try decoder.decode(MobileSyncPairingPayload.self, from: Data(json.utf8))
    }
}

@Test func pairingPayloadInitializerRejectsExpiredPayloads() {
    do {
        _ = try MobileSyncPairingPayload(
            macDeviceID: "mac-1",
            macDisplayName: nil,
            host: "100.64.1.2",
            port: 49831,
            expiresAt: Date(timeIntervalSince1970: 1_000),
            transport: .tailscale
        )
        Issue.record("Expected initializer to reject expired payload")
    } catch let error as MobileSyncPairingPayloadError {
        #expect(error == .expired)
    } catch {
        Issue.record("Expected expired payload error, got \(error)")
    }
}

@Test func pairingPayloadDecodeURLHonorsInjectedClock() throws {
    let json = """
    {
      "version": 1,
      "mac_device_id": "mac-1",
      "host": "100.64.1.2",
      "port": 49831,
      "expires_at": "1970-01-01T00:16:40Z",
      "transport": "tailscale"
    }
    """
    let url = try #require(URL(string: "cmux-ios://pair?v=1&payload=\(base64URLEncode(Data(json.utf8)))"))

    let decoded = try MobileSyncPairingPayload.decodeURL(
        url,
        now: Date(timeIntervalSince1970: 999)
    )

    #expect(decoded.host == "100.64.1.2")
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

@Test func frameCodecRejectsAZeroLengthFrameFloodAtTheCallerLimit() throws {
    let emptyFrame = try MobileSyncFrameCodec.encodeFrame(Data())
    var buffer = Data()
    for _ in 0..<10_000 {
        buffer.append(emptyFrame)
    }

    do {
        _ = try MobileSyncFrameCodec.decodeFrames(
            from: &buffer,
            maximumDecodedFrameCount: 16
        )
        Issue.record("Expected the decoded frame count limit to fail closed")
    } catch let error as MobileSyncFrameCodecError {
        #expect(error == .tooManyFrames(16))
        #expect(buffer.count == (10_000 - 16) * emptyFrame.count)
    }
}

@Test func frameCodecDefaultFrameCountLimitIsFinite() throws {
    let emptyFrame = try MobileSyncFrameCodec.encodeFrame(Data())
    var buffer = Data()
    for _ in 0...MobileSyncFrameCodec.defaultMaximumDecodedFrameCount {
        buffer.append(emptyFrame)
    }

    #expect(throws: MobileSyncFrameCodecError.tooManyFrames(
        MobileSyncFrameCodec.defaultMaximumDecodedFrameCount
    )) {
        _ = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
    }
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
