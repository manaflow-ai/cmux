import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("ChatArtifactLaneDescriptor")
struct ChatArtifactLaneDescriptorTests {
    @Test
    func roundTripsOnlyOpaqueTransferMetadata() throws {
        let descriptor = ChatArtifactLaneDescriptor(
            resourceID: "artifact:opaque-capability",
            totalSize: 42,
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let coding = ChatWireCoding()

        let data = try coding.encode(descriptor)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["resource_id"] as? String == descriptor.resourceID)
        #expect(object["total_size"] as? Int == 42)
        #expect(object["expires_at"] as? String == "2023-11-14T22:13:20Z")
        #expect(object["path"] == nil)
        #expect(try coding.decode(ChatArtifactLaneDescriptor.self, from: data) == descriptor)
    }
}
