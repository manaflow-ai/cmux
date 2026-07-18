import CmuxTerminalBackendService
import Foundation
import Testing

@Suite("Persistent backend identity derivation")
struct BackendServiceDescriptorTests {
    @Test("production identity remains stable")
    func productionIdentity() {
        let descriptor = BackendServiceDescriptor.production

        #expect(descriptor.bundleIdentifier == "com.cmuxterm.app")
        #expect(descriptor.serviceLabel == "com.cmuxterm.app.terminal-backend")
        #expect(descriptor.propertyListName == "com.cmuxterm.app.terminal-backend.plist")
        #expect(descriptor.sessionName == "cmux")
        #expect(descriptor.socketFileName == "cmux.sock")
        #expect(descriptor.stateNamespace == "cmux")
        #expect(
            descriptor.terminalClientUUID.uuidString.lowercased()
                == "73149cb2-e047-5bbb-a769-3658299fdf10"
        )
    }

    @Test("each tagged development bundle gets an isolated identity")
    func taggedDevelopmentIdentity() throws {
        let first = try #require(
            BackendServiceDescriptor(bundleIdentifier: "com.cmuxterm.app.debug.renderer-a")
        )
        let second = try #require(
            BackendServiceDescriptor(bundleIdentifier: "com.cmuxterm.app.debug.renderer-b")
        )

        #expect(first.serviceLabel == "com.cmuxterm.app.debug.renderer-a.terminal-backend")
        #expect(first.sessionName == "cmux-z3ogyutjsmgrkezxttum65pgym")
        #expect(first.socketFileName == "cmux-z3ogyutjsmgrkezxttum65pgym.sock")
        #expect(first.stateNamespace == first.sessionName)
        #expect(first.serviceLabel != second.serviceLabel)
        #expect(first.propertyListName != second.propertyListName)
        #expect(first.sessionName != second.sessionName)
        #expect(first.socketFileName != second.socketFileName)
        #expect(first.stateNamespace != second.stateNamespace)
        #expect(first.terminalClientUUID != second.terminalClientUUID)
    }

    @Test("Swift identity derivation matches the packaging contract vectors")
    func sharedIdentityVectors() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/backend-service-identity-vectors.json")
        let vectors = try JSONDecoder().decode(
            [IdentityVector].self,
            from: Data(contentsOf: fixtureURL)
        )

        for vector in vectors {
            let descriptor = try #require(
                BackendServiceDescriptor(bundleIdentifier: vector.bundleIdentifier)
            )
            let identity = try #require(
                BackendServiceIdentity(bundleIdentifier: vector.bundleIdentifier)
            )
            #expect(identity.normalizedBundleIdentifier == vector.normalizedBundleIdentifier)
            #expect(identity.token == vector.identityToken)
            #expect(descriptor.bundleIdentifier == vector.normalizedBundleIdentifier)
            #expect(descriptor.serviceLabel == vector.serviceLabel)
            #expect(descriptor.propertyListName == vector.propertyListName)
            #expect(descriptor.sessionName == vector.sessionName)
            #expect(descriptor.socketFileName == vector.socketFileName)
            #expect(descriptor.stateNamespace == vector.stateNamespace)
        }
    }

    @Test("unsafe bundle identifiers cannot become filesystem namespaces")
    func rejectsUnsafeIdentity() {
        #expect(BackendServiceDescriptor(bundleIdentifier: "") == nil)
        #expect(BackendServiceDescriptor(bundleIdentifier: "../../other-app") == nil)
        #expect(BackendServiceDescriptor(bundleIdentifier: "com.cmuxterm.app debug") == nil)
    }

    @Test(arguments: ["YES", "true", "1", "on", " yes "])
    func truthyBuildGate(value: String) {
        #expect(BackendServiceActivationPolicy(buildSettingValue: value).isEnabled)
    }

    @Test("debug override is explicit and does not change a disabled production policy")
    func explicitDevelopmentOverride() {
        #expect(
            !BackendServiceActivationPolicy(
                buildSettingValue: "NO",
                developmentOverrideValue: nil
            ).isEnabled
        )
        #expect(
            BackendServiceActivationPolicy(
                buildSettingValue: "NO",
                developmentOverrideValue: "1"
            ).isEnabled
        )
    }
}

private struct IdentityVector: Decodable {
    let bundleIdentifier: String
    let normalizedBundleIdentifier: String
    let identityToken: String
    let serviceLabel: String
    let propertyListName: String
    let sessionName: String
    let socketFileName: String
    let stateNamespace: String
}
