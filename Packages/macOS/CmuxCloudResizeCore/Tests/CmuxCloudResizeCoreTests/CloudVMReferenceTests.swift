import Testing

@testable import CmuxCloudResizeCore

/// `cmux vm ls` prints a machine's display name (or slug) when it has one, so every
/// id-taking verb must accept that label too (https://github.com/manaflow-ai/cmux/issues/42340).
@Suite("Cloud VM reference resolution")
struct CloudVMReferenceTests {
    private let machines = [
        CloudVMReference.Candidate(id: "vm-4be0afa3ef3fd95e026fe9ce10e48eb2", displayName: "probe-a", slug: "brave-otter"),
        CloudVMReference.Candidate(id: "vm-b213b889e53596b3f79f4fc611d38e23", displayName: nil, slug: "probe-b"),
        CloudVMReference.Candidate(id: "vm-e3a0747eaf59be2d40817c34b2c51c49", displayName: "shared", slug: "calm-heron"),
        CloudVMReference.Candidate(id: "vm-0f725dd3d5664d1d8c5e0a6f0b7c1e22", displayName: "shared", slug: "vivid-newt"),
    ]

    @Test("a label shown by vm ls resolves to its machine id")
    func labelResolvesToID() {
        #expect(CloudVMReference("probe-a").resolve(in: machines) == .id("vm-4be0afa3ef3fd95e026fe9ce10e48eb2"))
        #expect(CloudVMReference("probe-b").resolve(in: machines) == .id("vm-b213b889e53596b3f79f4fc611d38e23"))
        #expect(CloudVMReference("brave-otter").resolve(in: machines) == .id("vm-4be0afa3ef3fd95e026fe9ce10e48eb2"))
    }

    @Test("an exact id wins over a label that happens to match")
    func idWins() {
        let clash = machines + [CloudVMReference.Candidate(id: "probe-a", displayName: nil, slug: nil)]
        #expect(CloudVMReference("probe-a").resolve(in: clash) == .id("probe-a"))
    }

    @Test("a label shared by two machines is ambiguous and names both ids")
    func ambiguousLabel() {
        #expect(CloudVMReference("shared").resolve(in: machines) == .ambiguous([
            "vm-e3a0747eaf59be2d40817c34b2c51c49",
            "vm-0f725dd3d5664d1d8c5e0a6f0b7c1e22",
        ]))
    }

    @Test("no exact match leaves the reference to the id path")
    func unmatched() {
        #expect(CloudVMReference("probe").resolve(in: machines) == .unmatched)
        #expect(CloudVMReference("PROBE-A").resolve(in: machines) == .unmatched)
        #expect(CloudVMReference("").resolve(in: machines) == .unmatched)
    }

    @Test("only provider-shaped ids skip the vm list lookup")
    func idShape() {
        #expect(CloudVMReference("vm-4be0afa3ef3fd95e026fe9ce10e48eb2").looksLikeMachineID)
        #expect(CloudVMReference("4be0afa3ef3fd95e026fe9ce10e48eb2").looksLikeMachineID)
        #expect(!CloudVMReference("probe-a").looksLikeMachineID)
        #expect(!CloudVMReference("vm-4be0afa3ef3fd95e026fe9ce10e48eb").looksLikeMachineID)
        #expect(!CloudVMReference("vm-4be0afa3ef3fd95e026fe9ce10e48ebz").looksLikeMachineID)
    }
}
