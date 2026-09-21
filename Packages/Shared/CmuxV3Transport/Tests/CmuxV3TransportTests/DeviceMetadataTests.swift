import Foundation
import Testing
@testable import CmuxV3Transport

@Test
func deviceMetadataRoundTripsExactHostIdentity() throws {
    let metadata = try CmxV3DeviceMetadata(platform: .mac, instanceTag: "v3dog", displayName: "Office Mac", pairingEnabled: true, clientNamespace: "mac:com.cmuxterm.app.debug.v3dog")
    let data = try JSONEncoder().encode(metadata)
    let encoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(encoded["instance_tag"] as? String == "v3dog")
    #expect(encoded["pairing_enabled"] as? Bool == true)
    let decoded = try JSONDecoder().decode(CmxV3DeviceMetadata.self, from: data)
    #expect(decoded.platform == .mac)
    #expect(decoded.clientNamespace == "mac:com.cmuxterm.app.debug.v3dog")
    #expect(decoded.displayName == "Office Mac")
}

@Test
func deviceMetadataRejectsMalformedDiscoveryHints() throws {
    let valid: [String: Any] = ["platform": "mac", "instance_tag": "v3dog", "display_name": "Mac", "pairing_enabled": true, "client_namespace": "mac:com.cmuxterm.app.debug.v3dog"]
    for (field, value): (String, Any) in [
        ("instance_tag", ""), ("instance_tag", String(repeating: "x", count: 129)),
        ("instance_tag", "é"), ("display_name", String(repeating: "é", count: 129)),
        ("display_name", "Mac\nforged"), ("client_namespace", "ios:app"),
        ("client_namespace", "mac:"), ("platform", "ios")
    ] {
        var invalid = valid
        invalid[field] = value
        let data = try JSONSerialization.data(withJSONObject: invalid)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CmxV3DeviceMetadata.self, from: data) }
    }
}
