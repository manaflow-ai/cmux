import CmuxNextCodeRouter
import Testing
@testable import CmuxNextActions

/// The action catalog cannot import CmuxNextCodeRouter; its provider list
/// must name the same ids and the same CodeRouter support.
@Suite struct AccountsProviderIDTests {
    @Test func catalogProvidersMatchAIProvider() throws {
        for entry in AccountActionCatalog.accountProviders {
            let provider = try #require(AIProvider(rawValue: entry.id), "\(entry.id)")
            #expect(provider.displayName == entry.name)
            #expect((provider.codeRouterLink != .unsupported) == entry.linkable, "\(entry.id)")
        }
    }
}
