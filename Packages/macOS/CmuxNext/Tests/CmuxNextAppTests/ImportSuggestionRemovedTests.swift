import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxHomeCore
@testable import CmuxNextHome
@testable import CmuxNextImportCards
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-10-21: "yeah the bring your stuff to cmux is extrmeely questionable idk why that's
/// there + why they went to the chief thingy", and "yes to both" to removing it from the New Tab
/// and the Chief completely. The import suggestion is gone from the Chief's front page and the New
/// Tab page; importing lives in Settings › Import and the palette's Import from Other Apps….
@MainActor @Suite(.serialized) struct ImportSuggestionRemovedTests {
    /// The New Tab page gets no import cards: the agent page has no `importCards.act` op, and a
    /// page that still posts one is refused like any unknown request.
    @Test func theNewTabHasNoImportCards() {
        #expect(!AgentPageOps.all.contains(AgentPageOps.namespace + "importCards.act"))
        #expect(AgentPaneRequest(body: ["method": "importCards.act", "params": ["id": "agents.codex", "action": "start"]])
            == .unsupported("importCards.act"))
    }

    /// Import stays in the command palette: Import from Other Apps… is a palette action, and it
    /// opens Settings › Import.
    @Test func thePalettesImportCommandStillOpensSettingsImport() throws {
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        let descriptor = try #require(registry.descriptor(for: "import.open"))
        #expect(descriptor.surfaces.contains(.palette))
        let suite = "ImportSuggestionRemovedTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = FileManager.default.temporaryDirectory.appending(path: "import-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledger) }
        var routes: [String] = []
        let center = ImportSuggestionsCenter(defaults: defaults, ledgerURL: ledger)
        center.bind(into: registry, host: ImportCardsHost(runImport: { _, _, _ in throw CancellationError() },
                                                           importedProfiles: { [] },
                                                           openSettings: { routes.append($0) },
                                                           importClassic: { _ in nil }, importConductor: { _ in nil }))
        #expect(registry.isBound("import.open"))
        #expect(registry.perform("import.open", invocation: ActionInvocation(origin: .user)))
        #expect(routes == ["#/settings/import"])
    }
}
