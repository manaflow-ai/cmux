import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteAccountGateTests {
    @Test func everyCarrierStartsSignedOutAndRequiresTheAccountGate() async throws {
        let gate = MobileRemoteAccountGate()
        await #expect(throws: MobileRemoteAccountGateError.authenticationRequired) {
            try await gate.requireAccount()
        }

        try await gate.setAuthenticatedAccount(accountID: "account-a", sessionGeneration: 4)
        let account = try await gate.requireAccount()
        #expect(account.accountID == "account-a")
        #expect(account.sessionGeneration == 4)

        await gate.clear()
        await #expect(throws: MobileRemoteAccountGateError.authenticationRequired) {
            try await gate.requireAccount()
        }
    }

    @Test func malformedOrBlankAccountCannotOpenTheGate() async {
        let gate = MobileRemoteAccountGate()
        await #expect(throws: MobileRemoteAccountGateError.invalidAccount) {
            try await gate.setAuthenticatedAccount(accountID: " ", sessionGeneration: 1)
        }
        await #expect(throws: MobileRemoteAccountGateError.invalidAccount) {
            try await gate.setAuthenticatedAccount(accountID: "bad\0account", sessionGeneration: 1)
        }
        await #expect(throws: MobileRemoteAccountGateError.authenticationRequired) {
            try await gate.requireAccount()
        }
    }
}
