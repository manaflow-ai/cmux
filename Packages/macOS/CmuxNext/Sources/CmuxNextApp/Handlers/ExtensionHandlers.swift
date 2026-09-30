import AppKit
import CmuxNextActions
import CmuxNextBrowser

/// Chrome extension actions (`browser.extensions.*`, `browser.extension.*`).
/// They act on the focused Chromium tab's profile; Chromium owns the
/// extension state (BrowserExtensionStore mirrors it).
enum ExtensionHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("browser.extensions.menu", run: { invocation in
            let entry = try chromiumEntry(context, invocation)
            // The menu runs a tracking loop; a CLI or palette caller returns first.
            entry.chrome.presentExtensionsMenu()
        })
        registry.bind("browser.extensions.manage", run: { try openChromium(BrowserExtensionLinks.manage, context, $0) })
        registry.bind("browser.extensions.webStore", run: { try openChromium(BrowserExtensionLinks.webStore, context, $0) })
        registry.bind("browser.extensions.loadUnpacked", run: { invocation in
            let (tab, store) = try managedStore(context, invocation)
            if let path = invocation["path"]?.stringValue, !path.isEmpty {
                try load(path, store)
                return
            }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.message = ExtensionStrings.chooseFolder
            panel.prompt = ExtensionStrings.load
            let window = tab.contentView.window
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                _ = store.loadUnpacked(at: url.path)
            }
            if let window { panel.beginSheetModal(for: window, completionHandler: completion) } else { panel.begin(completionHandler: completion) }
        })
        registry.bind("browser.extension.run", run: { invocation in
            let entry = try chromiumEntry(context, invocation)
            let id = try extensionID(invocation, entry)
            entry.chrome.runExtensionAction(id)
        })
        registry.bind("browser.extension.options", run: { invocation in
            let (tab, store) = try managedStore(context, invocation)
            let id = try known(invocation, store)
            guard store.openOptions(id, from: tab) else { throw ActionFailure(message: ExtensionStrings.noOptions) }
        })
        bindToggle(registry, context, "browser.extension.pin") { $0.setPinned($1, true) }
        bindToggle(registry, context, "browser.extension.unpin") { $0.setPinned($1, false) }
        bindToggle(registry, context, "browser.extension.enable") { $0.setEnabled($1, true) }
        bindToggle(registry, context, "browser.extension.disable") { $0.setEnabled($1, false) }
        bindToggle(registry, context, "browser.extension.remove") { $0.uninstall($1) }
        registry.bind("browser.extension.command", run: { invocation in
            let (tab, store) = try managedStore(context, invocation)
            let id = try known(invocation, store)
            let name = invocation["command"]?.stringValue ?? ""
            let command = store.commands.first { $0.extensionID == id && $0.name == name }
                ?? BrowserExtensionCommand(extensionID: id, name: name, keyCode: 0, modifiers: 0)
            guard !name.isEmpty, store.run(command, in: tab) else { throw ActionFailure(message: ExtensionStrings.commandFailed) }
        })
    }

    private static func bindToggle(_ registry: ActionRegistry, _ context: AppActionContext, _ id: ActionID,
                                   _ body: @escaping (BrowserExtensionStore, String) -> Bool) {
        registry.bind(id, run: { invocation in
            let (_, store) = try managedStore(context, invocation)
            let extensionID = try known(invocation, store)
            guard body(store, extensionID) else { throw ActionFailure(message: ExtensionStrings.refused) }
        })
    }

    // MARK: Lookup

    /// The focused pane's Chromium tab.
    static func chromiumEntry(_ context: AppActionContext, _ invocation: ActionInvocation) throws -> BrowserEntry {
        guard case .browser(let entry)? = context.scope(invocation).pane?.currentContent, entry.tab is CEFTab else {
            throw ActionFailure(message: ExtensionStrings.needsChromiumTab)
        }
        return entry
    }

    static func managedStore(_ context: AppActionContext, _ invocation: ActionInvocation) throws -> (CEFTab, BrowserExtensionStore) {
        let entry = try chromiumEntry(context, invocation)
        guard let tab = entry.tab as? CEFTab else { throw ActionFailure(message: ExtensionStrings.needsChromiumTab) }
        let store = tab.extensionStore
        guard store.supportsManagement else { throw ActionFailure(message: ExtensionStrings.needsFork) }
        store.refresh()
        return (tab, store)
    }

    /// The `extension` argument as an installed extension id (an id or a
    /// case-insensitive name).
    private static func known(_ invocation: ActionInvocation, _ store: BrowserExtensionStore) throws -> String {
        let text = invocation["extension"]?.stringValue ?? ""
        guard let match = store.extensionInfo(matching: text) else { throw ActionFailure(message: ExtensionStrings.unknownExtension(text)) }
        return match.id
    }

    /// The `extension` argument as a toolbar action of the tab (an id or a
    /// case-insensitive name; the store's names count too).
    private static func extensionID(_ invocation: ActionInvocation, _ entry: BrowserEntry) throws -> String {
        let text = invocation["extension"]?.stringValue ?? ""
        guard let tab = entry.tab as? CEFTab else { throw ActionFailure(message: ExtensionStrings.needsChromiumTab) }
        tab.extensionStore.refresh()
        let id = tab.extensionActions.first(where: { $0.id == text })?.id
            ?? tab.extensionActions.first(where: { $0.name.localizedCaseInsensitiveCompare(text) == .orderedSame })?.id
            ?? tab.extensionStore.extensionInfo(matching: text)?.id
        guard let id, tab.extensionActions.contains(where: { $0.id == id }) else {
            throw ActionFailure(message: ExtensionStrings.unknownExtension(text))
        }
        return id
    }

    private static func load(_ path: String, _ store: BrowserExtensionStore) throws {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: (expanded as NSString).appendingPathComponent("manifest.json")) else {
            throw ActionFailure(message: ExtensionStrings.noManifest(path))
        }
        guard store.loadUnpacked(at: expanded) else { throw ActionFailure(message: ExtensionStrings.refused) }
    }

    /// Opens `url` in a new Chromium tab of the focused pane.
    private static func openChromium(_ url: URL, _ context: AppActionContext, _ invocation: ActionInvocation) throws {
        guard let pane = context.scope(invocation).pane else { throw ActionFailure(message: ExtensionStrings.needsPane) }
        pane.newBrowserTab(url: url, engine: BrowserEngineTag.cef.rawValue)
    }
}
