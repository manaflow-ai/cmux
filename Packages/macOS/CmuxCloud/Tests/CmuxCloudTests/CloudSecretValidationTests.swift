@testable import CmuxCloud
import Foundation
import Testing

/// Name and value rules, reserved names and the vault-wide limit.
@Suite struct CloudSecretValidationTests {
    @Test(arguments: ["A", "_", "ANTHROPIC_API_KEY", "lower_case", "_X9", String(repeating: "A", count: 128)])
    func acceptsValidNames(name: String) throws {
        try CloudSecretInput(name: name, value: "v").validate()
    }

    @Test(arguments: ["", "1ABC", "A-B", "A B", "A.B", "É", "A=B", String(repeating: "A", count: 129)])
    func rejectsInvalidNames(name: String) {
        #expect(throws: CloudSecretValidationError.invalidName(name)) {
            try CloudSecretInput(name: name, value: "v").validate()
        }
    }

    @Test(arguments: [
        "PATH", "HOME", "SHELL", "USER", "LOGNAME", "PWD", "TERM", "LD_PRELOAD", "LD_LIBRARY_PATH",
        "IFS", "ENV", "BASH_ENV", "PS4", "PROMPT_COMMAND", "OLDPWD", "LD_AUDIT", "ld_bind_now", "ifs",
        "path", "DYLD_INSERT_LIBRARIES", "dyld_x", "CMUX_SOCKET_PATH", "CMUX_", "cmux_anything"
    ])
    func rejectsReservedNames(name: String) {
        #expect(CloudSecretInput.isReservedName(name))
        #expect(throws: CloudSecretValidationError.reservedName(name)) {
            try CloudSecretInput(name: name, value: "v").validate()
        }
    }

    @Test(arguments: ["PATHS", "MY_PATH", "XCMUX_TOKEN", "TERM_PROGRAM_X", "GH_TOKEN", "ENVIRONMENT", "LDAP_URL", "IFS_X"])
    func nearReservedNamesAreAllowed(name: String) throws {
        #expect(!CloudSecretInput.isReservedName(name))
        try CloudSecretInput(name: name, value: "v").validate()
    }

    @Test
    func rejectsBadValues() throws {
        #expect(throws: CloudSecretValidationError.emptyValue("A")) {
            try CloudSecretInput(name: "A", value: "").validate()
        }
        #expect(throws: CloudSecretValidationError.multilineValue("A")) {
            try CloudSecretInput(name: "A", value: "line1\nline2").validate()
        }
        #expect(throws: CloudSecretValidationError.multilineValue("A")) {
            try CloudSecretInput(name: "A", value: "line1\rline2").validate()
        }
        #expect(throws: CloudSecretValidationError.valueTooLarge("A")) {
            try CloudSecretInput(name: "A", value: String(repeating: "x", count: CloudSecretInput.maxValueBytes + 1)).validate()
        }
        try CloudSecretInput(name: "A", value: String(repeating: "x", count: CloudSecretInput.maxValueBytes)).validate()
        // Size counts UTF-8 bytes, not characters.
        #expect(throws: CloudSecretValidationError.valueTooLarge("A")) {
            try CloudSecretInput(name: "A", value: String(repeating: "é", count: CloudSecretInput.maxValueBytes / 2 + 1)).validate()
        }
        // Spaces, quotes and = are ordinary value bytes.
        try CloudSecretInput(name: "A", value: " a = \"b\" 'c' # d ").validate()
    }

    @Test
    func invalidInputWritesNothing() async throws {
        let storage = InMemoryCloudSecretVaultStorage()
        let vault = CloudSecretVault(storage: storage)
        await #expect(throws: CloudSecretValidationError.reservedName("PATH")) {
            try await vault.set(
                [CloudSecretInput(name: "GOOD", value: "1"), CloudSecretInput(name: "PATH", value: "/bin")],
                scope: .all,
                source: .manual
            )
        }
        #expect(try storage.load() == nil)
        #expect(try await vault.records().isEmpty)
    }

    @Test
    func vaultHoldsAtMostMaxSecrets() async throws {
        let vault = CloudSecretVault(storage: InMemoryCloudSecretVaultStorage())
        let full = (0..<CloudSecretVault.maxSecrets).map { CloudSecretInput(name: "K\($0)", value: "v") }
        try await vault.set(full, scope: .all, source: .manual)
        await #expect(throws: CloudSecretValidationError.tooMany) {
            try await vault.set([CloudSecretInput(name: "ONE_MORE", value: "v")], scope: .machine("m1"), source: .manual)
        }
        // Updating an existing secret at the limit is still allowed.
        let changes = try await vault.set([CloudSecretInput(name: "K0", value: "new")], scope: .all, source: .manual)
        #expect(changes.map(\.kind) == [.updated])
        #expect(try await vault.records().count == CloudSecretVault.maxSecrets)
    }

    @Test
    func vaultHoldsAtMostAboutOneMegabyteOfValues() async throws {
        let storage = InMemoryCloudSecretVaultStorage()
        let vault = CloudSecretVault(storage: storage)
        let big = String(repeating: "v", count: CloudSecretInput.maxValueBytes)
        let most = (0..<31).map { CloudSecretInput(name: "BIG_\($0)", value: big) }
        try await vault.set(most, scope: .all, source: .manual)
        let saved = try storage.load()
        await #expect(throws: CloudSecretValidationError.self) {
            try await vault.set((31..<34).map { CloudSecretInput(name: "BIG_\($0)", value: big) }, scope: .machine("m1"), source: .manual)
        }
        #expect(try storage.load() == saved)
        #expect(try await vault.records().count == 31)
        // Replacing a value with a smaller one is always allowed.
        let changes = try await vault.set([CloudSecretInput(name: "BIG_0", value: "small")], scope: .all, source: .manual)
        #expect(changes.map(\.kind) == [.updated])
    }

    @Test
    func anInvalidNameIsNeverShown() {
        // A token pasted into the name position must not be echoed back.
        let pasted = "sk-live-pasted-token-0123456789"
        let validation = CloudSecretValidationError.invalidName(pasted).errorDescription ?? ""
        #expect(!validation.isEmpty)
        #expect(!validation.contains(pasted))
        #expect(!validation.contains("sk-live"))
        let dotenv = CloudSecretDotenvError(line: 2, reason: .invalidName(pasted)).errorDescription ?? ""
        #expect(!dotenv.contains(pasted))
        #expect(!dotenv.contains("sk-live"))
        #expect(dotenv.contains("2"))
    }

    @Test
    func errorDescriptionsNameTheVariable() {
        #expect(CloudSecretValidationError.reservedName("PATH").errorDescription?.contains("PATH") == true)
        #expect(CloudSecretValidationError.multilineValue("TOKEN").errorDescription?.contains("TOKEN") == true)
        #expect(CloudSecretValidationError.tooMany.errorDescription?.isEmpty == false)
    }
}
