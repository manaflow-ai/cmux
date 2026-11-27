public import CmuxNextActions
import CmuxNextBrowserImport
import CmuxNextImportSuggestions

extension ImportSuggestionsCenter {
    /// Binds `import.list`, `import.card`, `import.suggest` and `import.open` (ImportActionCatalog)
    /// and starts the cards with `host`.
    public func bind(into registry: ActionRegistry, host: ImportCardsHost) {
        start(host: host, registry: registry)
        let refusedWhileOff: @MainActor () -> String? = { [weak self] in
            self?.isEnabled == false ? ImportSuggestionStrings.cardsOff : nil
        }
        // Every card Settings › Import lists, as JSON text (`cmux import list`).
        registry.bind("import.list", unavailable: refusedWhileOff, invoke: { [weak self, weak registry] _ in
            guard let self, let registry else { return }
            let text = ImportCardJSON.text(list())
            registry.track(result: Task { .success(["cards": .string(text)]) })
        })
        registry.bind("import.card", unavailable: refusedWhileOff, invoke: { [weak self, weak registry] invocation in
            guard let self, let registry else { return }
            let id = invocation.arguments["id"]?.stringValue ?? ""
            let name = invocation.arguments["action"]?.stringValue ?? ""
            guard let action = ImportCardAction(rawValue: name) else { return registry.refuse(ImportSuggestionStrings.unknownButton(name)) }
            // Reading another app's data is the person's call: an agent, a script or another
            // client may raise, dismiss or open a card but never start one, nor open the
            // person-only Import from Browser window. A page's press asks the person natively
            // before anything starts (`ImportSuggestionsCenter.perform`).
            if action.startsWork || action == .more, !Self.mayPress(invocation.origin) {
                return registry.refuse(ImportSuggestionStrings.personOnly)
            }
            do {
                try perform(id, action, caller: invocation)
            } catch {
                registry.refuseNotFound(ImportSuggestionStrings.noSuchCard(id))
            }
        })
        // An agent's request only adds a card; nothing is read until the person clicks Import on it.
        registry.bind("import.suggest", unavailable: refusedWhileOff, invoke: { [weak self, weak registry] invocation in
            guard let self, let registry else { return }
            let name = invocation.arguments["browser"]?.stringValue ?? ""
            let text = invocation.arguments["site"]?.stringValue ?? ""
            guard let browser = Self.browser(name) else { return registry.refuse(ImportSuggestionStrings.unknownBrowser(name)) }
            guard let site = ImportRequest.site(text) else { return registry.refuse(ImportSuggestionStrings.invalidSite(text)) }
            raise(browser: browser, site: site, reason: invocation.arguments["reason"]?.stringValue ?? "", caller: invocation)
        })
        registry.bind("import.open", invoke: { [weak self] _ in self?.openSettings() })
    }

    /// Who may press a card's Import, Resume, Try Again or More Options: the person's click in
    /// this app, which starts at once, or a control a first-party page drew (Settings › Import),
    /// which is never the person's own gesture and so starts nothing before the person confirms
    /// a native dialog. Never the CLI, MCP, a script or another client.
    nonisolated static func mayPress(_ origin: ActionOrigin) -> Bool {
        origin == .user || origin == .page
    }

    /// A browser by registry id (`chrome`) or name (`Google Chrome`), one whose cookies cmux reads.
    nonisolated static func browser(_ name: String) -> ImportBrowser? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        let browser = ImportBrowser(rawValue: key) ?? ImportBrowser.allCases.first { $0.displayName.lowercased() == key }
        guard let browser, browser.kind == .browser, !browser.refusesSessionData,
              [.chromium, .firefox, .safari].contains(browser.family) else { return nil }
        return browser
    }
}
