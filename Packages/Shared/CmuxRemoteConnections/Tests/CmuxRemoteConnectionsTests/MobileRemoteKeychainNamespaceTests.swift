import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteKeychainNamespaceTests {
    @Test(arguments: ["", "   ", "$(AppIdentifierPrefix)com.cmux", "TEAM.*.cmux"])
    func rejectsImpreciseSignedAccessGroups(accessGroup: String) {
        #expect(throws: MobileRemoteSecretStoreError.invalidNamespace) {
            try MobileRemoteKeychainNamespace(accessGroup: accessGroup)
        }
    }

    @Test func usesOneVersionedServiceWithoutCallerSuppliedHostMetadata() throws {
        let namespace = try MobileRemoteKeychainNamespace(
            accessGroup: "TEAMID.dev.cmux.remote.tests"
        )
        #expect(namespace.service == MobileRemoteKeychainNamespace.defaultService)
        #expect(!namespace.service.contains("example.com"))
    }
}
