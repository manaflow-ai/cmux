import Testing
@testable import CMUXAgentLaunch

@Suite("ACP host capabilities")
struct ACPHostCapabilitiesTests {
    private let capabilities = ACPHostCapabilities()

    private func protocolVersion(for requested: Int?) -> Int? {
        capabilities.initializeResult(clientProtocolVersion: requested)["protocolVersion"] as? Int
    }

    /// ACP versions are a single MAJOR integer and this host speaks 1. Pinned
    /// as a literal, not read back off the host: asserting the host's field
    /// against itself passes for any value, including a version ACP has not
    /// defined.
    private let hostVersion = 1

    @Test("The host speaks ACP version 1 on the wire")
    func hostVersionIsPinned() {
        #expect(capabilities.protocolVersion == hostVersion)
        #expect(protocolVersion(for: nil) == hostVersion)
    }

    @Test("Initialize echoes the supported client version")
    func supportedVersionIsReturned() {
        #expect(protocolVersion(for: hostVersion) == hostVersion)
    }

    @Test("Initialize returns the host version for a lower client version")
    func lowerVersionDoesNotDowngradeHost() {
        #expect(protocolVersion(for: hostVersion - 1) == hostVersion)
    }

    @Test("Initialize returns the host version for a higher client version")
    func higherVersionDoesNotUpgradeHost() {
        #expect(protocolVersion(for: hostVersion + 1) == hostVersion)
    }

    @Test("Initialize returns the host version when the client omits one")
    func missingVersionUsesHostVersion() {
        #expect(protocolVersion(for: nil) == hostVersion)
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

    @Test("The writes flag follows the caller in both directions", arguments: [false, true])
    func writesFlagIsControlledByCaller(_ writesEnabled: Bool) throws {
        let result = ACPHostCapabilities(writesEnabled: writesEnabled)
            .initializeResult(clientProtocolVersion: nil)
        let metadata = try #require(result["_meta"] as? [String: Any])
        let cmux = try #require(metadata["cmux"] as? [String: Any])
        #expect(cmux["writes"] as? Bool == writesEnabled)
    }

    @Test("Only underscore-prefixed methods are advertised as extensions")
    func extensionMethodsAreDerivedFromTheCaseList() {
        #expect(ACPHostMethod.extensionMethodNames == ["_cmux/session/list"])
        for name in ACPHostMethod.extensionMethodNames {
            #expect(name.hasPrefix("_"), "\(name) is advertised but is not an extension name")
        }
        // A standard ACP method must never be advertised as a cmux extension.
        #expect(ACPHostMethod.extensionMethodNames.contains(ACPHostMethod.sessionLoad.rawValue) == false)
    }
}
