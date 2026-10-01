import Testing
@testable import CmuxNextActions

@Suite struct AccountsCatalogTests {
    @Test func accountActionsHaveCLIVerbsUnderAccountsAndTakeNoSecrets() throws {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        for id in ["accounts.show", "accounts.refresh", "accounts.reauthenticate", "accounts.connect", "accounts.remove"] {
            let descriptor = try #require(registry.descriptor(for: ActionID(rawValue: id)))
            #expect(descriptor.cliName.hasPrefix("accounts "), "`cmux coderouter` stays the legacy CLI's verb")
            for argument in descriptor.arguments {
                #expect(!["key", "token", "secret", "apikey"].contains(argument.name.lowercased()))
            }
        }
    }
}
