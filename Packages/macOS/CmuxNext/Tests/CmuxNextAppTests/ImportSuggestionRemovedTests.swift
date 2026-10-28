import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxHomeCore
@testable import CmuxNextHome
@testable import CmuxNextImportCards
import CmuxNextWakeups
import Foundation
import Testing

/// Leo 2026-10-21: "yeah the bring your stuff to cmux is extrmeely questionable idk why that's
/// there + why they went to the chief thingy", and "yes to both" to removing it from the New Tab
/// and the Chief completely. The import suggestion is gone from the Chief's front page and the New
/// Tab page; importing lives in Settings › Import and the palette's Import from Other Apps….
@MainActor @Suite(.serialized) struct ImportSuggestionRemovedTests {
    /// The empty Chief conversation's front page holds no import suggestion row and no import card,
    /// shown or hidden.
    @Test func theChiefFrontPageHasNoImportSuggestion() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let view = HomeHostView(services: services, conversation: ConversationID("conv_no_import_suggestion").rawValue)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutSubtreeIfNeeded()
        let page = view.transcript.firstRun.everyDescendant
        #expect(!page.contains { $0.accessibilityIdentifier() == "cmux.home.importSuggestion" }, "the front page holds the import row")
        #expect(!page.contains { String(describing: type(of: $0)).contains("Import") }, "the front page holds an import view")
        #expect(!page.contains { $0.texts.contains { $0.localizedCaseInsensitiveContains("Bring your stuff") } })
    }

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
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = FileManager.default.temporaryDirectory.appending(path: "import-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledger) }
        var routes: [String] = []
        let center = ImportSuggestionsCenter(defaults: defaults, ledgerURL: ledger)
        center.bind(into: registry, host: ImportCardsHost(runImport: { _, _, _ in throw CancellationError() },
                                                           importedProfiles: { [] },
                                                           openSettings: { routes.append($0) },
                                                           importClassic: { _ in nil },
                                                           appEvents: AppEvents(center: NotificationCenter())))
        #expect(registry.isBound("import.open"))
        #expect(registry.perform("import.open", invocation: ActionInvocation(origin: .user)))
        #expect(routes == ["#/settings/import"])
    }
}

extension NSView {
    /// This view and every view under it, hidden ones too.
    fileprivate var everyDescendant: [NSView] {
        [self] + subviews.flatMap(\.everyDescendant)
    }

    /// The view's own label or button text.
    fileprivate var texts: [String] {
        if let field = self as? NSTextField { return [field.stringValue] }
        if let button = self as? NSButton { return [button.title] }
        return []
    }
}
