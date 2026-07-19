import Testing

@testable import CmuxAgentChat

@Suite("ChatArtifactTransferPolicy")
struct ChatArtifactTransferPolicyTests {
    @Test("default chunk fits mobile sync frame")
    func defaultChunkFitsFrame() {
        let policy = ChatArtifactTransferPolicy.defaultPolicy
        #expect(policy.maxRawChunkBytes == 3 * 1024 * 1024)
        #expect(policy.estimatedEnvelopeByteCount(rawByteCount: policy.maxRawChunkBytes) < policy.mobileSyncFrameLimitBytes)
        #expect(policy.clampedChunkLength(10 * 1024 * 1024) == policy.maxRawChunkBytes)
    }
}
