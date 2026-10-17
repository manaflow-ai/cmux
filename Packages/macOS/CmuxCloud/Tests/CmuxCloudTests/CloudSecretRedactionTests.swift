@testable import CmuxCloud
import Foundation
import Security
import Testing

/// Values never reach text, plus the small value types and the Keychain item shape.
@Suite struct CloudSecretRedactionTests {
    let secret = "sk-ant-super-secret-value"

    @Test
    func inputNeverRendersItsValue() {
        let input = CloudSecretInput(name: "ANTHROPIC_API_KEY", value: secret)
        var dumped = ""
        dump(input, to: &dumped)
        let renderings = [
            "\(input)",
            String(describing: input),
            String(reflecting: input),
            dumped,
            "\([input])",
            String(describing: Mirror(reflecting: input).children.map { "\($0.label ?? ""): \($0.value)" })
        ]
        for text in renderings {
            #expect(!text.contains(secret))
            #expect(text.contains("ANTHROPIC_API_KEY"))
        }
    }

    @Test
    func planNeverRendersValues() async throws {
        let vault = CloudSecretVault(storage: InMemoryCloudSecretVaultStorage())
        try await vault.set([CloudSecretInput(name: "TOKEN", value: secret)], scope: .all, source: .manual)
        let plan = try await vault.plan(machineID: "m1")
        #expect(plan.toSend.first?.value == secret)
        var dumped = ""
        dump(plan, to: &dumped)
        for text in ["\(plan)", String(reflecting: plan), dumped] {
            #expect(!text.contains(secret))
            #expect(text.contains("TOKEN"))
        }
    }

    @Test
    func metadataSurfacesCarryNoValue() async throws {
        let vault = CloudSecretVault(storage: InMemoryCloudSecretVaultStorage())
        try await vault.set([CloudSecretInput(name: "TOKEN", value: secret)], scope: .all, source: .manual)
        let plan = try await vault.plan(machineID: "m1")
        try await vault.recordDelivered(machineID: "m1", plan: plan, at: Date())
        let records = try await vault.records()
        let deliveries = try await vault.deliveries()
        let status = try await vault.status(machineID: "m1", namesOnMachine: nil)
        let preview = try await vault.preview([CloudSecretInput(name: "TOKEN", value: secret)], scope: .all)
        let texts = [
            String(reflecting: records),
            String(reflecting: deliveries),
            String(reflecting: status),
            String(reflecting: preview)
        ]
        for text in texts { #expect(!text.contains(secret)) }
    }

    // MARK: Value types

    @Test
    func scopeWireValuesRoundTrip() throws {
        let scopes: [CloudSecretScope] = [.all, .project("github.com/o/r"), .machine("vm_123"), .project("a:b")]
        for scope in scopes {
            #expect(CloudSecretScope(wireValue: scope.wireValue) == scope)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let encoded = try encoder.encode(scope)
            #expect(String(data: encoded, encoding: .utf8) == "\"\(scope.wireValue)\"")
            #expect(try JSONDecoder().decode(CloudSecretScope.self, from: encoded) == scope)
        }
        #expect(CloudSecretScope.all.rank < CloudSecretScope.project("p").rank)
        #expect(CloudSecretScope.project("p").rank < CloudSecretScope.machine("m").rank)
        for invalid in ["", "ALL", "project:", "machine:", "team:x", "project"] {
            #expect(CloudSecretScope(wireValue: invalid) == nil)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CloudSecretScope.self, from: Data(#""bogus""#.utf8))
        }
    }

    @Test
    func sourceWireValuesRoundTrip() throws {
        let sources: [CloudSecretSource] = [.manual, .dotenv(".env.local"), .shell, .ghCLI]
        for source in sources {
            #expect(CloudSecretSource(wireValue: source.wireValue) == source)
            #expect(try JSONDecoder().decode(CloudSecretSource.self, from: JSONEncoder().encode(source)) == source)
        }
        #expect(try JSONDecoder().decode(CloudSecretSource.self, from: Data(#""future-source""#.utf8)) == .manual)
    }

    @Test
    func catalogListsTheContractPresets() {
        let names = CloudSecretCatalog.presets.map(\.name)
        #expect(names == [
            "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GH_TOKEN", "GEMINI_API_KEY", "OPENROUTER_API_KEY",
            "XAI_API_KEY", "GROQ_API_KEY", "MISTRAL_API_KEY", "DEEPSEEK_API_KEY", "HF_TOKEN", "NPM_TOKEN"
        ])
        #expect(Set(names).count == names.count)
        for preset in CloudSecretCatalog.presets {
            #expect((try? CloudSecretInput.validateName(preset.name)) != nil)
            #expect(!CloudSecretInput.isReservedName(preset.name))
            #expect(preset.docsURL?.scheme == "https")
            #expect(CloudSecretCatalog.isWellKnown(preset.name))
        }
        #expect(CloudSecretCatalog.isWellKnown("GITHUB_TOKEN"))
        #expect(!CloudSecretCatalog.isWellKnown("MY_APP_SECRET"))
        #expect(CloudSecretCatalog.wellKnownNames.contains("GITHUB_TOKEN"))
    }

    // MARK: Keychain item shape

    @Test
    func keychainServiceIsSeparatedPerBundle() {
        #expect(KeychainCloudSecretVaultStorage.serviceName(bundleIdentifier: nil) == "com.cmuxterm.cloud-secrets")
        #expect(KeychainCloudSecretVaultStorage.serviceName(bundleIdentifier: "com.cmuxterm.app") == "com.cmuxterm.cloud-secrets")
        #expect(KeychainCloudSecretVaultStorage.serviceName(bundleIdentifier: "com.cmuxterm.app.debug.my-tag") == "com.cmuxterm.cloud-secrets.com.cmuxterm.app.debug.my-tag")
        #expect(KeychainCloudSecretVaultStorage(service: "s").account == "vault-v1")
    }

    @Test
    func keychainItemIsThisDeviceOnlyAndNotSynchronizable() {
        let storage = KeychainCloudSecretVaultStorage(service: "svc")
        for dataProtection in [true, false] {
            let query = storage.addQuery(data: Data("doc".utf8), dataProtection: dataProtection)
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService as String] as? String == "svc")
            #expect(query[kSecAttrAccount as String] as? String == "vault-v1")
            #expect(query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
            #expect((query[kSecUseDataProtectionKeychain as String] as? Bool ?? false) == dataProtection)
        }
        let update = storage.updateAttributes(data: Data())
        #expect(update[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}
