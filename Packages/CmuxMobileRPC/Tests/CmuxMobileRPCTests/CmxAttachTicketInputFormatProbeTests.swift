import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

/// Tests the version/format probe in `CmxAttachTicketInput.decode`: a pairing
/// payload this build cannot decode must throw a *typed* unsupported-format /
/// unsupported-version error whenever the payload names a format marker, so
/// the UI can say "update the app" instead of "invalid code". Garbage without
/// a marker keeps throwing the original opaque error.
@Suite struct CmxAttachTicketInputFormatProbeTests {
    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test func compactShortKeyAttachPayloadThrowsUnsupportedPayloadFormat() {
        // The compact grammar newer Macs put in the QR
        // (https://github.com/manaflow-ai/cmux/pull/5727): top-level "v".
        let json = #"{"v":2,"m":"mac","e":4102444800}"#
        let url = "cmux-ios://attach?payload=\(base64URLEncode(Data(json.utf8)))"

        #expect(throws: MobileSyncPairingPayloadError.unsupportedPayloadFormat(2)) {
            try CmxAttachTicketInput.decode(url)
        }
    }

    @Test func newerLongKeyAttachPayloadThrowsUnsupportedVersion() {
        // A future long-key ticket whose keys this decoder no longer fits, but
        // that still declares its "version".
        let json = #"{"version":3,"renamedWorkspaceField":"ws"}"#
        let url = "cmux-ios://attach?payload=\(base64URLEncode(Data(json.utf8)))"

        #expect(throws: MobileSyncPairingPayloadError.unsupportedVersion(3)) {
            try CmxAttachTicketInput.decode(url)
        }
    }

    @Test func newerPairPayloadVersionThrowsUnsupportedVersion() {
        // Today's pair grammar already validates the version field itself; this
        // pins the typed error for a decodable payload with a newer version.
        let json = """
        {
          "version": 2,
          "mac_device_id": "mac",
          "host": "100.71.210.41",
          "port": 58465,
          "expires_at": "2099-01-01T00:00:01Z",
          "transport": "tailscale"
        }
        """
        let url = "cmux-ios://pair?v=2&payload=\(base64URLEncode(Data(json.utf8)))"

        #expect(throws: MobileSyncPairingPayloadError.unsupportedVersion(2)) {
            try CmxAttachTicketInput.decode(url)
        }
    }

    @Test func undecodablePairPayloadWithVersionMarkerThrowsUnsupportedVersion() {
        // A future pair grammar that dropped keys this decoder requires, but
        // kept the "version" marker.
        let json = #"{"version":4,"endpoint":"merged-host-port"}"#
        let url = "cmux-ios://pair?v=4&payload=\(base64URLEncode(Data(json.utf8)))"

        #expect(throws: MobileSyncPairingPayloadError.unsupportedVersion(4)) {
            try CmxAttachTicketInput.decode(url)
        }
    }

    @Test func unreadableAttachPayloadWithVersionQueryItemThrowsUnsupportedVersion() {
        // Two unreadable shapes, both stamped `v=2` on the URL: "not-base64"
        // happens to decode as base64 but yields non-JSON bytes (caught at the
        // JSON decode), while "!!!" is not base64 at all (caught before any
        // decode). The version marker must win over the generic failure in both.
        #expect(throws: MobileSyncPairingPayloadError.unsupportedVersion(2)) {
            try CmxAttachTicketInput.decode("cmux-ios://attach?v=2&payload=not-base64")
        }
        #expect(throws: MobileSyncPairingPayloadError.unsupportedVersion(2)) {
            try CmxAttachTicketInput.decode("cmux-ios://attach?v=2&payload=!!!")
        }
    }

    @Test func unreadablePairPayloadWithVersionQueryItemThrowsUnsupportedVersion() {
        #expect(throws: MobileSyncPairingPayloadError.unsupportedVersion(3)) {
            try CmxAttachTicketInput.decode("cmux-ios://pair?v=3&payload=not-base64")
        }
        #expect(throws: MobileSyncPairingPayloadError.unsupportedVersion(3)) {
            try CmxAttachTicketInput.decode("cmux-ios://pair?v=3&payload=!!!")
        }
    }

    @Test func unreadablePayloadWithCurrentOrNoVersionStaysInvalidURL() {
        // A current-version `v` cannot explain the unreadable payload, and a
        // missing `v` carries no marker: both stay the plain invalid-URL error.
        #expect(throws: MobileSyncPairingPayloadError.invalidURL) {
            try CmxAttachTicketInput.decode("cmux-ios://attach?v=1&payload=!!!")
        }
        #expect(throws: MobileSyncPairingPayloadError.invalidURL) {
            try CmxAttachTicketInput.decode("cmux-ios://attach?payload=!!!")
        }
        #expect(throws: MobileSyncPairingPayloadError.invalidURL) {
            try CmxAttachTicketInput.decode("cmux-ios://pair?v=1&payload=!!!")
        }
    }

    @Test func markerlessGarbageStillThrowsOpaqueError() {
        // No format marker anywhere: this really is an unreadable code, so the
        // probe must not invent a version mismatch.
        let json = #"{"hello":"world"}"#
        let url = "cmux-ios://attach?v=1&payload=\(base64URLEncode(Data(json.utf8)))"

        #expect(throws: (any Error).self) {
            try CmxAttachTicketInput.decode(url)
        }
        do {
            _ = try CmxAttachTicketInput.decode(url)
        } catch is DecodingError {
            // Expected: the original decode failure, not a probe result.
        } catch {
            Issue.record("expected the original DecodingError, got \(error)")
        }
    }

    @Test func validTicketsStillDecode() throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.71.210.41", port: 58465)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "ws",
            terminalID: nil,
            macDeviceID: "mac",
            macDisplayName: "Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = "cmux-ios://attach?v=1&payload=\(base64URLEncode(try encoder.encode(ticket)))"

        let decoded = try CmxAttachTicketInput.decode(url)

        #expect(decoded.macDeviceID == "mac")
    }
}
