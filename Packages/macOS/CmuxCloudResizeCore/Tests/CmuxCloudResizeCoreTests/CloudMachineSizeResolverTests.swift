import Testing
@testable import CmuxCloudResizeCore

@Suite("Cloud machine size resolution")
struct CloudMachineSizeResolverTests {
    private let resolver = CloudMachineSizeResolver()

    @Test("legacy sizes keep their compatibility ladder")
    func legacySize() {
        let option = resolver.resolve(memoryMb: 8_192, useLegacyLadderFallback: true)
        #expect(option == CloudMachineSizeOption(memoryMb: 8_192, servedVcpus: 4, servedDiskMb: 32_768))
    }

    @Test("server values take precedence over the legacy ladder")
    func serverValues() {
        let option = resolver.resolve(
            memoryMb: 8_192,
            servedVcpus: 6,
            servedDiskMb: 40_960,
            fallbackDiskMb: 131_072,
            useLegacyLadderFallback: true
        )
        #expect(option?.vcpus == 6)
        #expect(option?.diskMb == 40_960)
    }

    @Test("missing per-size disk uses the server ceiling")
    func serverCeiling() {
        let option = resolver.resolve(memoryMb: 20_480, servedVcpus: 10, fallbackDiskMb: 131_072)
        #expect(option?.diskMb == 131_072)
        #expect(option?.vcpus == 10)
    }

    @Test("invalid per-size disk does not make the size unavailable")
    func invalidDiskFallsBack() {
        let option = resolver.resolve(memoryMb: 8_192, servedDiskMb: 0, fallbackDiskMb: 131_072)
        #expect(option?.diskMb == 131_072)
    }

    @Test("non-positive memory is rejected")
    func invalidMemory() {
        #expect(resolver.resolve(memoryMb: 0) == nil)
        #expect(resolver.resolve(memoryMb: -1) == nil)
    }
}
