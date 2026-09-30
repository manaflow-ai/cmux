import Testing
@testable import CMUXAgentLaunch

@Suite("ACP host capabilities")
struct ACPHostCapabilitiesTests {
    @Test("Initialize negotiates down, echoes lower versions, and defaults missing versions")
    func protocolVersionNegotiation() {
        let higher = ACPHostCapabilities.initializeResult(clientProtocolVersion: 99)
        let lower = ACPHostCapabilities.initializeResult(clientProtocolVersion: 0)
        let missing = ACPHostCapabilities.initializeResult(clientProtocolVersion: nil)

        #expect(higher["protocolVersion"] as? Int == ACPHostCapabilities.protocolVersion)
        #expect(lower["protocolVersion"] as? Int == 0)
        #expect(missing["protocolVersion"] as? Int == ACPHostCapabilities.protocolVersion)
    }

    @Test("Initialize advertises the read-only host capability shape")
    func advertisesReadOnlyCapabilities() throws {
        let result = ACPHostCapabilities.initializeResult(clientProtocolVersion: nil)
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

}
