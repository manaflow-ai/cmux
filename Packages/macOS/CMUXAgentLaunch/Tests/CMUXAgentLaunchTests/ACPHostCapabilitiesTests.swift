import Testing
@testable import CMUXAgentLaunch

@Suite("ACP host capabilities")
struct ACPHostCapabilitiesTests {
    private let capabilities = ACPHostCapabilities()

    private func protocolVersion(for requested: Int?) -> Int? {
        capabilities.initializeResult(clientProtocolVersion: requested)["protocolVersion"] as? Int
    }

    @Test("Initialize echoes the supported client version")
    func supportedVersionIsReturned() {
        #expect(protocolVersion(for: capabilities.protocolVersion) == capabilities.protocolVersion)
    }

    @Test("Initialize returns the host version for a lower client version")
    func lowerVersionDoesNotDowngradeHost() {
        #expect(protocolVersion(for: capabilities.protocolVersion - 1) == capabilities.protocolVersion)
    }

    @Test("Initialize returns the host version for a higher client version")
    func higherVersionDoesNotUpgradeHost() {
        #expect(protocolVersion(for: capabilities.protocolVersion + 1) == capabilities.protocolVersion)
    }

    @Test("Initialize returns the host version when the client omits one")
    func missingVersionUsesHostVersion() {
        #expect(protocolVersion(for: nil) == capabilities.protocolVersion)
    }

    @Test("Initialize advertises the read-only host capability shape")
    func advertisesReadOnlyCapabilities() throws {
        let result = capabilities.initializeResult(clientProtocolVersion: nil)
        let agents = try #require(result["agentCapabilities"] as? [String: Any])
        let prompts = try #require(agents["promptCapabilities"] as? [String: Any])
        let metadata = try #require(result["_meta"] as? [String: Any])
        let cmux = try #require(metadata["cmux"] as? [String: Any])

        #expect(agents["loadSession"] as? Bool == true)
        #expect(prompts["image"] as? Bool == false)
        #expect(prompts["audio"] as? Bool == false)
        #expect(prompts["embeddedContext"] as? Bool == false)
        #expect((result["authMethods"] as? [Any])?.isEmpty == true)
        #expect(cmux["writes"] as? Bool == false)
        #expect(cmux["surfaces"] as? Bool == false)
        #expect(cmux["extensionMethods"] as? [String] == ACPHostMethod.extensionMethodNames)
    }

    @Test("The host can explicitly keep writes disabled")
    func writesFlagIsControlledByCaller() throws {
        let result = ACPHostCapabilities(writesEnabled: false)
            .initializeResult(clientProtocolVersion: nil)
        let metadata = try #require(result["_meta"] as? [String: Any])
        let cmux = try #require(metadata["cmux"] as? [String: Any])
        #expect(cmux["writes"] as? Bool == false)
    }
}
