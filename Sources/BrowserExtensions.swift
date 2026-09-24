// Portions of this file are adapted from Search, a WebKit browser by Office
// Commun, https://github.com/driceroland/Search, MIT licensed.
// See THIRD_PARTY_LICENSES.md for the complete notice.

import AppKit
import SwiftUI
import WebKit

struct BrowserExtensionInstallation: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var version: String
    var enabled: Bool
    var fromStore: Bool
}

@available(macOS 15.4, *)
@MainActor
final class BrowserExtensions: NSObject, ObservableObject {
    static let shared = BrowserExtensions()

    @Published private(set) var installed: [BrowserExtensionInstallation] = []
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?

    private let fileManager: FileManager
    private let root: URL
    private let metadataURL: URL
    private var controllers: [String: Controller] = [:]

    private override init() {
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        fileManager = .default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        root = appSupport.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("BrowserExtensions", isDirectory: true)
        metadataURL = root.appendingPathComponent("installed.json")
        super.init()
        installed = (try? JSONDecoder().decode([BrowserExtensionInstallation].self, from: Data(contentsOf: metadataURL))) ?? []
    }

    static func attach(_ configuration: WKWebViewConfiguration, websiteDataStore: WKWebsiteDataStore) {
        configuration.webExtensionController = shared.controller(for: websiteDataStore).controller
    }

    func register(_ panel: BrowserPanel) {
        let controller = controller(for: panel.websiteDataStore)
        controller.register(panel)
        loadInstalled(in: controller)
    }

    func unregister(panelID: UUID, websiteDataStore: WKWebsiteDataStore) {
        let key = storeKey(for: websiteDataStore)
        controllers[key]?.unregister(panelID: panelID)
    }

    func installStoreExtension(from text: String) {
        guard let id = BrowserExtensionArchive.id(in: text) else {
            lastError = BrowserExtensionArchive.Error.invalidID.localizedDescription
            return
        }
        guard !installed.contains(where: { $0.id == id }) else {
            lastError = "That extension is already installed."
            return
        }
        busy = true
        lastError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { busy = false }
            do {
                let crx = try await BrowserExtensionArchive.fetch(id: id)
                let zip = try BrowserExtensionArchive.verifiedZip(crx, id: id)
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                let stage = root.appendingPathComponent(".staging-\(id)", isDirectory: true)
                try? fileManager.removeItem(at: stage)
                try BrowserExtensionArchive.unpack(zip, into: stage, fileManager: fileManager)
                try await admit(stage: stage, id: id, fromStore: true)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func installUnpacked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Load Extension"
        panel.message = "Choose a folder containing manifest.json."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let id = "local-\(UUID().uuidString.lowercased())"
        busy = true
        lastError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { busy = false }
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                let stage = root.appendingPathComponent(".staging-\(id)", isDirectory: true)
                try? fileManager.removeItem(at: stage)
                try BrowserExtensionArchive.copyUnpacked(from: source, into: stage, fileManager: fileManager)
                try await admit(stage: stage, id: id, fromStore: false)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = enabled
        save()
        for controller in controllers.values {
            if enabled { load(id: id, in: controller) } else { controller.unload(id: id) }
        }
    }

    func performAction(_ id: String) {
        for controller in controllers.values {
            guard let context = controller.contexts[id], let tab = controller.activeTabAdapter else { continue }
            context.performAction(for: tab)
            return
        }
    }

    func remove(_ id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed.remove(at: index)
        save()
        for controller in controllers.values { controller.unload(id: id) }
        try? fileManager.removeItem(at: extensionFolder(id))
    }

    private func admit(stage: URL, id: String, fromStore: Bool) async throws {
        let extensionObject = try await WKWebExtension(resourceBaseURL: stage)
        let name = extensionObject.displayName ?? id
        let permissions = extensionObject.requestedPermissions.map(\.rawValue).sorted()
        guard confirmInstall(name: name, version: extensionObject.version ?? "?", permissions: permissions) else {
            try? fileManager.removeItem(at: stage)
            return
        }
        let destination = extensionFolder(id)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: stage, to: destination)
        installed.append(BrowserExtensionInstallation(id: id, name: name, version: extensionObject.version ?? "?", enabled: true, fromStore: fromStore))
        save()
        for controller in controllers.values { load(id: id, in: controller) }
    }

    private func confirmInstall(name: String, version: String, permissions: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add \(name)?"
        var detail = "Version \(version)"
        if !permissions.isEmpty { detail += "\n\nRequests: \(permissions.joined(separator: ", "))" }
        detail += "\n\nExtensions can read or change pages covered by the permissions above."
        alert.informativeText = detail
        alert.addButton(withTitle: "Add Extension")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func loadInstalled(in controller: Controller) {
        for item in installed where item.enabled { load(id: item.id, in: controller) }
    }

    private func load(id: String, in controller: Controller) {
        guard controller.contexts[id] == nil,
              let item = installed.first(where: { $0.id == id }), item.enabled else { return }
        let folder = extensionFolder(id)
        Task { @MainActor [weak self, weak controller] in
            guard let self, let controller else { return }
            do {
                let extensionObject = try await WKWebExtension(resourceBaseURL: folder)
                let context = WKWebExtensionContext(for: extensionObject)
                context.uniqueIdentifier = id
                context.baseURL = URL(string: "chrome-extension://\(id)/")!
                // Installation is the explicit consent boundary. Optional
                // permissions remain denied until WebKit asks at runtime.
                for permission in extensionObject.requestedPermissions {
                    context.setPermissionStatus(.grantedExplicitly, for: permission)
                }
                for pattern in extensionObject.requestedPermissionMatchPatterns {
                    context.setPermissionStatus(.grantedExplicitly, for: pattern)
                }
                try controller.controller.load(context)
                controller.contexts[id] = context
                objectWillChange.send()
            } catch {
                self.lastError = "\(item.name) could not start: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(installed).write(to: metadataURL, options: [.atomic])
    }

    private func extensionFolder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    private func storeKey(for store: WKWebsiteDataStore) -> String {
        if let identifier = store.identifier?.uuidString { return identifier }
        return "ephemeral-\(ObjectIdentifier(store).hashValue)"
    }

    private func controller(for store: WKWebsiteDataStore) -> Controller {
        let key = storeKey(for: store)
        if let existing = controllers[key] { return existing }
        let configuration = WKWebExtensionController.Configuration.default()
        configuration.defaultWebsiteDataStore = store
        if let webViewConfiguration = configuration.webViewConfiguration {
            webViewConfiguration.websiteDataStore = store
            configuration.webViewConfiguration = webViewConfiguration
        }
        let controller = Controller(owner: self, key: key, configuration: configuration)
        controllers[key] = controller
        return controller
    }

    @MainActor
    fileprivate final class Controller: NSObject, WKWebExtensionControllerDelegate {
        unowned let owner: BrowserExtensions
        let key: String
        let controller: WKWebExtensionController
        let window: BrowserExtensionWindow
        var contexts: [String: WKWebExtensionContext] = [:]
        var adapters: [UUID: BrowserExtensionTab] = [:]
        var panels: [UUID: WeakBrowserPanel] = [:]

        var activeTabAdapter: BrowserExtensionTab? {
            if let panel = livePanels.first(where: { $0.webView.window?.isKeyWindow == true }) {
                return adapters[panel.id]
            }
            return adapters.values.first
        }

        init(owner: BrowserExtensions, key: String, configuration: WKWebExtensionController.Configuration) {
            self.owner = owner; self.key = key
            controller = WKWebExtensionController(configuration: configuration)
            window = BrowserExtensionWindow()
            super.init()
            window.owner = self
            controller.delegate = self
            controller.didOpenWindow(window)
        }

        func register(_ panel: BrowserPanel) {
            panels[panel.id] = WeakBrowserPanel(panel)
            if adapters[panel.id] == nil {
                let adapter = BrowserExtensionTab(panel: panel, owner: self)
                adapters[panel.id] = adapter
                controller.didOpenTab(adapter)
            } else {
                adapters[panel.id]?.panel = panel
            }
        }

        func unregister(panelID: UUID) {
            if let adapter = adapters.removeValue(forKey: panelID) { controller.didCloseTab(adapter, windowIsClosing: false) }
            panels[panelID] = nil
        }

        func unload(id: String) {
            guard let context = contexts.removeValue(forKey: id) else { return }
            try? controller.unload(context)
        }

        var livePanels: [BrowserPanel] { panels.values.compactMap(\.panel) }

        func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [window] }
        func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { window }

        func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? { nil }
        func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? { nil }

        func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
            guard let url = extensionContext.optionsPageURL, let panel = livePanels.first else { return }
            panel.openLinkInNewTab(url: url)
        }

        func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
            let detail = permissions.map(\.rawValue).sorted().joined(separator: ", ")
            return owner.confirmRuntimePermission(extensionContext.webExtension.displayName ?? extensionContext.uniqueIdentifier, detail: detail) ? (permissions, nil) : ([], nil)
        }

        func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
            // A host permission request is a security boundary. WebKit already
            // granted manifest patterns; unexpected runtime URLs are denied by
            // default instead of silently expanding page access.
            return ([], nil)
        }

        func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
            let detail = matchPatterns.map(\.string).sorted().joined(separator: ", ")
            return owner.confirmRuntimePermission(extensionContext.webExtension.displayName ?? extensionContext.uniqueIdentifier, detail: detail) ? (matchPatterns, nil) : ([], nil)
        }

        func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
            owner.objectWillChange.send()
        }

        func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
            // WebKit owns the popup lifecycle. The toolbar can present the
            // action's NSPopover when it is available; leaving it unopened here
            // prevents an extension from creating an unanchored window.
        }
    }

    private func confirmRuntimePermission(_ name: String, detail: String) -> Bool {
        let alert = NSAlert(); alert.messageText = "Allow \(name) to access more?"; alert.informativeText = detail
        alert.addButton(withTitle: "Allow"); alert.addButton(withTitle: "Deny")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@available(macOS 15.4, *)
@MainActor
private final class WeakBrowserPanel {
    weak var panel: BrowserPanel?
    init(_ panel: BrowserPanel) { self.panel = panel }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var owner: BrowserExtensions.Controller?

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let owner else { return [] }
        return Array(owner.adapters.values)
    }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let owner else { return nil }
        if let panel = owner.livePanels.first(where: { $0.webView.window?.isKeyWindow == true }) {
            return owner.adapters[panel.id]
        }
        return owner.adapters.values.first
    }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { NSScreen.main?.frame ?? .zero }
    func frame(for context: WKWebExtensionContext) -> CGRect { NSApp.keyWindow?.frame ?? .zero }
    func focus(for context: WKWebExtensionContext) async throws { NSApp.activate(ignoringOtherApps: true) }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserExtensionTab: NSObject, WKWebExtensionTab {
    weak var panel: BrowserPanel?
    unowned let owner: BrowserExtensions.Controller

    init(panel: BrowserPanel, owner: BrowserExtensions.Controller) { self.panel = panel; self.owner = owner }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner.window }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { owner.livePanels.firstIndex(where: { $0.id == panel?.id }) ?? NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { panel?.webView }
    func title(for context: WKWebExtensionContext) -> String? { panel?.pageTitle }
    func url(for context: WKWebExtensionContext) -> URL? { panel?.webView.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(panel?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { panel?.webView.window?.isKeyWindow == true }
    func isPinned(for context: WKWebExtensionContext) -> Bool { false }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { panel?.isPlayingAudio == true }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(panel?.webView.pageZoom ?? 1) }
    func size(for context: WKWebExtensionContext) -> CGSize { panel?.webView.bounds.size ?? .zero }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws { panel?.webView.pageZoom = zoomFactor }
    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        panel?.navigateWithoutInsecureHTTPPrompt(to: url, recordTypedNavigation: false)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws { panel?.reload() }
    func goBack(for context: WKWebExtensionContext) async throws { panel?.goBack() }
    func goForward(for context: WKWebExtensionContext) async throws { panel?.goForward() }
    func activate(for context: WKWebExtensionContext) async throws { panel?.webView.window?.makeKeyAndOrderFront(nil) }
    func close(for context: WKWebExtensionContext) async throws { panel?.webView.window?.performClose(nil) }
}

@available(macOS 15.4, *)
struct BrowserExtensionsToolbarButton: View {
    @ObservedObject private var extensions = BrowserExtensions.shared
    @State private var isPresented = false
    @State private var storeLink = ""

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "puzzlepiece.extension")
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help("Extensions")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                    Text("Extensions").font(.headline)
                    if extensions.installed.isEmpty { Text("No extensions installed.").foregroundStyle(.secondary) }
                    ForEach(extensions.installed) { item in
                        HStack {
                            Button(item.name) { extensions.performAction(item.id) }
                                .buttonStyle(.link)
                                .lineLimit(1)
                            Spacer()
                            Toggle("", isOn: Binding(get: { item.enabled }, set: { extensions.setEnabled(item.id, $0) }))
                                .labelsHidden()
                            Button("Remove") { extensions.remove(item.id) }.buttonStyle(.link)
                        }
                    }
                    Divider()
                    TextField("Chrome Web Store link or ID", text: $storeLink)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Add") { extensions.installStoreExtension(from: storeLink); storeLink = "" }
                            .disabled(BrowserExtensionArchive.id(in: storeLink) == nil || extensions.busy)
                        Button("Load Unpacked…") { extensions.installUnpacked() }
                    }
                    if let error = extensions.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                    if #unavailable(macOS 15.4) { Text("Requires macOS 15.4 or later.") }
            }
            .padding(14)
            .frame(width: 340)
        }
    }
}
