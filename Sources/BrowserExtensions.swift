// Portions of this file are adapted from Search, a WebKit browser by Office
// Commun, https://github.com/driceroland/Search, MIT licensed.
// See THIRD_PARTY_LICENSES.md for the complete notice.

import AppKit
import CmuxBrowser
import Combine
import WebKit

/// One installed extension, persisted in `installed.json`.
///
/// `grantedPermissions` and `grantedMatchPatterns` record exactly what the
/// user accepted. Loading grants only those, so an update or a reload of an
/// unpacked folder that asks for more cannot widen its access silently.
struct BrowserExtensionInstallation: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var version: String
    var enabled: Bool
    var fromStore: Bool
    var grantedPermissions: [String]
    var grantedMatchPatterns: [String]
    /// For an unpacked extension: the folder it was loaded from, so Reload
    /// can copy the developer's latest edits in again.
    var sourcePath: String?

    init(
        id: String,
        name: String,
        version: String,
        enabled: Bool,
        fromStore: Bool,
        grantedPermissions: [String],
        grantedMatchPatterns: [String],
        sourcePath: String?
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.enabled = enabled
        self.fromStore = fromStore
        self.grantedPermissions = grantedPermissions
        self.grantedMatchPatterns = grantedMatchPatterns
        self.sourcePath = sourcePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        fromStore = try container.decode(Bool.self, forKey: .fromStore)
        grantedPermissions = try container.decodeIfPresent([String].self, forKey: .grantedPermissions) ?? []
        grantedMatchPatterns = try container.decodeIfPresent([String].self, forKey: .grantedMatchPatterns) ?? []
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
    }
}

/// Hosts Chrome extensions on WebKit's `WKWebExtensionController`.
///
/// One controller exists per persistent website data store, so each browser
/// profile keeps its own extension storage and cookies. Private (non-
/// persistent) browsing gets no controller: as in Chrome, extensions do not
/// run there.
///
/// Deliberately not supported, for security: Chrome native messaging hosts,
/// API shims for Chrome APIs WebKit does not implement, and user-agent
/// spoofing inside extension contexts.
@available(macOS 15.4, *)
@MainActor
final class BrowserExtensions: NSObject, ObservableObject {
    static let shared = BrowserExtensions()

    /// Custom scheme extension pages are served from, matching Chrome so
    /// servers that allow-list an extension origin recognize it.
    static let extensionScheme = "chrome-extension"

    @Published private(set) var installed: [BrowserExtensionInstallation] = []
    @Published private(set) var busyID: String?
    @Published private(set) var lastError: String?
    /// Bumped when an extension's toolbar action changes (icon, badge, title).
    @Published private(set) var actionRevision = 0
    private(set) var errors: [String: [String]] = [:]

    private let fileManager = FileManager.default
    let root: URL
    private let metadataURL: URL
    private var controllers: [String: Controller] = [:]
    /// Where a popup hangs: a pinned button, else the extensions button.
    struct AnchorKey: Hashable {
        let panelID: UUID
        let extensionID: String?
    }

    /// Toolbar anchors, for action popups.
    private var anchors: [AnchorKey: WeakView] = [:]
    private var lastFocusedPanelID: UUID?
    private let managerPages = NSHashTable<WKWebView>.weakObjects()
    private let storePages = NSHashTable<WKWebView>.weakObjects()
    private var question: Task<Bool, Never>?
    private var popover: NSPopover?
    private var stateObservation: AnyCancellable?

    private override init() {
        WKWebExtension.MatchPattern.registerCustomURLScheme(Self.extensionScheme)
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        root = appSupport.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("BrowserExtensions", isDirectory: true)
        metadataURL = root.appendingPathComponent("installed.json")
        super.init()
        installed = (try? JSONDecoder().decode([BrowserExtensionInstallation].self, from: Data(contentsOf: metadataURL))) ?? []
        stateObservation = objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.pushStateToPages() }
    }

    // MARK: - Web view configuration

    /// Attaches extension support to a browser web view configuration. Must
    /// run before the web view is created: WebKit reads the controller once.
    static func configure(_ configuration: WKWebViewConfiguration, websiteDataStore: WKWebsiteDataStore) {
        if websiteDataStore.isPersistent {
            configuration.webExtensionController = shared.controller(for: websiteDataStore).controller
        }
        BrowserExtensionPageBridge.install(on: configuration)
    }

    // MARK: - Tabs

    /// Tracks `panel` as an extension tab in its profile's controller.
    /// Called whenever the panel binds a web view, including after a profile
    /// switch, so a panel is only ever a tab of one controller.
    func register(_ panel: BrowserPanel) {
        let key = storeKey(for: panel.websiteDataStore)
        for (otherKey, other) in controllers where otherKey != key { other.unregister(panelID: panel.id) }
        guard panel.websiteDataStore.isPersistent else {
            controllers[key]?.unregister(panelID: panel.id)
            return
        }
        let controller = controller(for: panel.websiteDataStore)
        controller.register(panel)
        loadInstalled(in: controller)
    }

    func unregister(panelID: UUID) {
        for controller in controllers.values { controller.unregister(panelID: panelID) }
        anchors = anchors.filter { $0.key.panelID != panelID }
        if lastFocusedPanelID == panelID { lastFocusedPanelID = nil }
    }

    func didFocus(_ panel: BrowserPanel) {
        let previous = lastFocusedPanelID
        lastFocusedPanelID = panel.id
        guard previous != panel.id else { return }
        for controller in controllers.values { controller.didActivate(panelID: panel.id, previous: previous) }
        actionRevision &+= 1
    }

    func setAnchor(_ view: NSView, for key: AnchorKey) {
        anchors[key] = WeakView(view)
    }

    private func anchorView(panelID: UUID?, extensionID: String) -> NSView? {
        func live(_ key: AnchorKey) -> NSView? {
            guard let view = anchors[key]?.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return nil }
            return view
        }
        for id in [panelID, lastFocusedPanelID].compactMap({ $0 }) {
            if let view = live(AnchorKey(panelID: id, extensionID: extensionID)) ?? live(AnchorKey(panelID: id, extensionID: nil)) {
                return view
            }
        }
        return nil
    }

    fileprivate var focusedPanelID: UUID? { lastFocusedPanelID }

    // MARK: - Toolbar actions

    struct ActionItem: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
        let badge: String
        let isEnabled: Bool
    }

    /// Toolbar actions for the extensions loaded in `panel`'s profile.
    func actionItems(for panel: BrowserPanel) -> [ActionItem] {
        guard let controller = controllers[storeKey(for: panel.websiteDataStore)] else { return [] }
        let tab = controller.adapters[panel.id]
        return installed.compactMap { item in
            guard item.enabled, let context = controller.contexts[item.id] else { return nil }
            let action = context.action(for: tab)
            let label = action?.label ?? ""
            return ActionItem(
                id: item.id,
                name: label.isEmpty ? item.name : label,
                icon: action?.icon(for: CGSize(width: 16, height: 16)) ?? context.webExtension.icon(for: CGSize(width: 16, height: 16)),
                badge: action?.badgeText ?? "",
                isEnabled: action?.isEnabled ?? true
            )
        }
    }

    /// Runs an extension's toolbar action for `panel`, the way clicking its
    /// button in Chrome does. A popup is shown by the controller delegate.
    func performAction(_ id: String, in panel: BrowserPanel) {
        guard let controller = controllers[storeKey(for: panel.websiteDataStore)],
              let context = controller.contexts[id] else { return }
        let tab = controller.adapters[panel.id]
        if let tab { context.userGesturePerformed(in: tab) }
        context.performAction(for: tab)
    }

    fileprivate func presentPopup(
        _ action: WKWebExtension.Action,
        extensionID: String,
        panel: BrowserPanel?
    ) {
        guard let webView = action.popupWebView else { return }
        // A pinned button, else the extensions button. With both hidden, the
        // popup hangs from the top trailing corner of the page.
        let anchor: NSView
        let anchorRect: NSRect
        if let view = anchorView(panelID: panel?.id, extensionID: extensionID) {
            anchor = view
            anchorRect = view.bounds
        } else if let page = panel?.webView, page.window != nil {
            anchor = page
            anchorRect = NSRect(x: page.bounds.maxX - 24, y: page.isFlipped ? 0 : page.bounds.maxY - 1, width: 1, height: 1)
        } else {
            action.closePopup()
            return
        }
        popover?.close()
        let controller = NSViewController()
        let size = webView.intrinsicContentSize
        let width = size.width > 0 ? min(max(size.width, 200), 800) : 360
        let height = size.height > 0 ? min(max(size.height, 100), 600) : 480
        webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        controller.view = webView
        controller.preferredContentSize = webView.frame.size
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = BrowserExtensionPopoverDelegate.shared
        BrowserExtensionPopoverDelegate.shared.action = action
        popover.show(relativeTo: anchorRect, of: anchor, preferredEdge: .maxY)
        self.popover = popover
    }

    // MARK: - Installing

    /// Installs a Chrome Web Store extension from a store link or bare id.
    func installStoreExtension(from text: String) {
        guard let id = ChromeExtensionPackage.extensionID(in: text) else {
            lastError = Self.describe(ChromeExtensionPackage.Failure.notAnExtensionID)
            return
        }
        guard !installed.contains(where: { $0.id == id }) else {
            lastError = String(localized: "browser.extensions.error.alreadyInstalled", defaultValue: "That extension is already installed.")
            return
        }
        guard busyID == nil else { return }
        busyID = id
        lastError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { busyID = nil }
            let stage = root.appendingPathComponent(".staging-\(id)", isDirectory: true)
            do {
                let crx = try await ChromeExtensionPackage.download(extensionID: id)
                let zip = try ChromeExtensionPackage.verifiedZip(crx, extensionID: id)
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                try await Self.detached { try ChromeExtensionPackage.unpack(zip, into: stage) }
                try await admit(stage: stage, id: id, fromStore: true, sourcePath: nil)
            } catch {
                try? fileManager.removeItem(at: stage)
                lastError = Self.describe(error)
            }
        }
    }

    /// Loads an unpacked extension folder chosen by the user.
    func installUnpacked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "browser.extensions.loadUnpacked.prompt", defaultValue: "Load Extension")
        panel.message = String(localized: "browser.extensions.loadUnpacked.message", defaultValue: "Choose the folder that contains the extension's manifest.json.")
        guard panel.runModal() == .OK, let source = panel.url, busyID == nil else { return }
        let id = "local-\(UUID().uuidString.lowercased())"
        let stage = root.appendingPathComponent(".staging-\(id)", isDirectory: true)
        busyID = id
        lastError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { busyID = nil }
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                try await Self.detached { try ChromeExtensionPackage.copyUnpacked(from: source, into: stage) }
                try await admit(stage: stage, id: id, fromStore: false, sourcePath: source.path)
            } catch {
                try? fileManager.removeItem(at: stage)
                lastError = Self.describe(error)
            }
        }
    }

    /// Reads a staged extension, asks the user, and on consent moves it into
    /// place and loads it. On refusal nothing is left behind.
    private func admit(stage: URL, id: String, fromStore: Bool, sourcePath: String?) async throws {
        let found = try await WKWebExtension(resourceBaseURL: stage)
        let name = found.displayName ?? id
        guard await ask(
            title: String(
                format: String(localized: "browser.extensions.install.title", defaultValue: "Add “%@” to cmux?"),
                name
            ),
            detail: Self.describeAccess(found),
            icon: found.icon(for: CGSize(width: 64, height: 64)),
            confirm: String(localized: "browser.extensions.install.confirm", defaultValue: "Add Extension")
        ) else {
            try? fileManager.removeItem(at: stage)
            return
        }
        let destination = folder(for: id)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: stage, to: destination)
        installed.removeAll { $0.id == id }
        installed.append(BrowserExtensionInstallation(
            id: id,
            name: name,
            version: found.version ?? "?",
            enabled: true,
            fromStore: fromStore,
            grantedPermissions: found.requestedPermissions.map(\.rawValue).sorted(),
            grantedMatchPatterns: found.requestedPermissionMatchPatterns.map(\.string).sorted(),
            sourcePath: sourcePath
        ))
        save()
        for controller in controllers.values { load(id: id, in: controller) }
    }

    // MARK: - Managing

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = enabled
        save()
        for controller in controllers.values {
            if enabled { load(id: id, in: controller) } else { controller.unload(id: id) }
        }
    }

    func remove(_ id: String) {
        guard let item = installed.first(where: { $0.id == id }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await ask(
                title: String(
                    format: String(localized: "browser.extensions.remove.title", defaultValue: "Remove “%@”?"),
                    item.name
                ),
                detail: String(localized: "browser.extensions.remove.detail", defaultValue: "Its settings and data are removed too."),
                icon: nil,
                confirm: String(localized: "browser.extensions.remove.confirm", defaultValue: "Remove")
            ) else { return }
            installed.removeAll { $0.id == id }
            errors[id] = nil
            save()
            var layout = BrowserToolbarLayout.load()
            layout.hide(.pinnedExtension(id))
            layout.save()
            for controller in controllers.values { controller.unload(id: id) }
            try? fileManager.removeItem(at: folder(for: id))
        }
    }

    /// Copies an unpacked extension in again from its source folder, as
    /// Chrome's developer-mode Reload does. New access is asked for again.
    func reload(_ id: String) {
        guard let item = installed.first(where: { $0.id == id }), let sourcePath = item.sourcePath, busyID == nil else { return }
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let stage = root.appendingPathComponent(".staging-\(id)", isDirectory: true)
        busyID = id
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { busyID = nil }
            do {
                try await Self.detached { try ChromeExtensionPackage.copyUnpacked(from: source, into: stage) }
                try await replaceInstalled(item, with: stage)
            } catch {
                try? fileManager.removeItem(at: stage)
                lastError = Self.describe(error)
            }
        }
    }

    /// Swaps a staged new version in for `item`. When the new version asks
    /// for access beyond what was granted, the user is asked first.
    private func replaceInstalled(_ item: BrowserExtensionInstallation, with stage: URL) async throws {
        let found = try await WKWebExtension(resourceBaseURL: stage)
        if !Self.accessIsSubset(found, of: item) {
            guard await ask(
                title: String(
                    format: String(localized: "browser.extensions.moreAccess.title", defaultValue: "“%@” asks for more access"),
                    item.name
                ),
                detail: Self.describeAccess(found),
                icon: found.icon(for: CGSize(width: 64, height: 64)),
                confirm: String(localized: "browser.extensions.moreAccess.confirm", defaultValue: "Allow")
            ) else {
                try? fileManager.removeItem(at: stage)
                return
            }
        }
        for controller in controllers.values { controller.unload(id: item.id) }
        try? fileManager.removeItem(at: folder(for: item.id))
        try fileManager.moveItem(at: stage, to: folder(for: item.id))
        if let index = installed.firstIndex(where: { $0.id == item.id }) {
            installed[index].name = found.displayName ?? item.name
            installed[index].version = found.version ?? item.version
            installed[index].grantedPermissions = found.requestedPermissions.map(\.rawValue).sorted()
            installed[index].grantedMatchPatterns = found.requestedPermissionMatchPatterns.map(\.string).sorted()
        }
        errors[item.id] = nil
        save()
        for controller in controllers.values { load(id: item.id, in: controller) }
    }

    func openOptions(_ id: String) {
        for controller in controllers.values {
            if let url = controller.contexts[id]?.optionsPageURL {
                _ = controller.openTab(url: url, focus: true)
                return
            }
        }
    }

    /// Opens `cmux://extensions` in a new tab beside `panel`.
    func openManagerPage(from panel: BrowserPanel) {
        panel.openLinkInNewTab(url: ChromeExtensionsManagerPage.url)
    }

    func openStore(from panel: BrowserPanel) {
        panel.openLinkInNewTab(url: ChromeWebStorePage.storeHomeURL)
    }

    // MARK: - Loading

    private func loadInstalled(in controller: Controller) {
        for item in installed where item.enabled { load(id: item.id, in: controller) }
    }

    private func load(id: String, in controller: Controller) {
        guard controller.contexts[id] == nil, !controller.loading.contains(id),
              let item = installed.first(where: { $0.id == id }), item.enabled else { return }
        controller.loading.insert(id)
        let folder = folder(for: id)
        Task { @MainActor [weak self, weak controller] in
            guard let self, let controller else { return }
            defer { controller.loading.remove(id) }
            do {
                let found = try await WKWebExtension(resourceBaseURL: folder)
                let context = WKWebExtensionContext(for: found)
                context.uniqueIdentifier = id
                if let base = URL(string: "\(Self.extensionScheme)://\(id)/") { context.baseURL = base }
                context.isInspectable = !item.fromStore
                // Grant exactly what the user accepted. Anything the current
                // manifest asks for beyond that stays ungranted until the
                // user approves it through an update or reload prompt.
                let permissions = Set(item.grantedPermissions)
                for permission in found.requestedPermissions where permissions.contains(permission.rawValue) {
                    context.setPermissionStatus(.grantedExplicitly, for: permission)
                }
                let patterns = Set(item.grantedMatchPatterns)
                for pattern in found.requestedPermissionMatchPatterns where patterns.contains(pattern.string) {
                    context.setPermissionStatus(.grantedExplicitly, for: pattern)
                }
                guard installed.first(where: { $0.id == id })?.enabled == true, controller.contexts[id] == nil else { return }
                try controller.controller.load(context)
                controller.contexts[id] = context
                observeErrors(of: context, in: controller)
                actionRevision &+= 1
            } catch {
                noteError(Self.describe(error), for: id)
            }
        }
    }

    private var errorObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var lastRevival: [String: Date] = [:]

    /// Surfaces WebKit's own context errors on `cmux://extensions`, and
    /// restarts an extension whose background worker failed to start. WebKit
    /// records that failure and never retries, so without this the extension
    /// stays dead until relaunch. Restarts are limited to one a minute.
    private func observeErrors(of context: WKWebExtensionContext, in controller: Controller) {
        let key = ObjectIdentifier(context)
        if let existing = errorObservers[key] { NotificationCenter.default.removeObserver(existing) }
        errorObservers[key] = NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification,
            object: context,
            queue: .main
        ) { [weak self, weak context, weak controller] _ in
            MainActor.assumeIsolated {
                guard let self, let context, let controller else { return }
                let id = context.uniqueIdentifier
                guard controller.contexts[id] === context else { return }
                let messages = context.errors.map { $0.localizedDescription }
                self.errors[id] = Array(messages.suffix(20))
                self.objectWillChange.send()
                let workerFailed = context.errors.contains { error in
                    let nsError = error as NSError
                    return nsError.domain == WKWebExtensionContext.errorDomain
                        && nsError.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
                }
                guard workerFailed,
                      Date().timeIntervalSince(self.lastRevival[id] ?? .distantPast) > 60 else { return }
                self.lastRevival[id] = Date()
                controller.unload(id: id)
                self.load(id: id, in: controller)
            }
        }
    }

    fileprivate func stopObservingErrors(of context: WKWebExtensionContext) {
        if let observer = errorObservers.removeValue(forKey: ObjectIdentifier(context)) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func noteError(_ text: String, for id: String) {
        errors[id] = Array((errors[id, default: []] + [text]).suffix(20))
        objectWillChange.send()
    }

    // MARK: - Updates

    /// Checks the store about once a day for newer versions of installed
    /// store extensions. An update that asks for more access is asked about.
    private func checkForUpdatesIfDue() {
        let key = "browser.extensions.lastUpdateCheck"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 60 * 60 * 20 else { return }
        UserDefaults.standard.set(Date(), forKey: key)
        for item in installed where item.fromStore {
            Task { @MainActor [weak self] in await self?.update(item) }
        }
    }

    private func update(_ item: BrowserExtensionInstallation) async {
        guard let url = ChromeExtensionPackage.updateCheckURL(forExtensionID: item.id, version: item.version),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8),
              let offered = ChromeExtensionPackage.offeredVersion(inUpdateCheckResponse: xml),
              offered != item.version else { return }
        let stage = root.appendingPathComponent(".staging-\(item.id)", isDirectory: true)
        do {
            let zip = try ChromeExtensionPackage.verifiedZip(
                try await ChromeExtensionPackage.download(extensionID: item.id),
                extensionID: item.id
            )
            try await Self.detached { try ChromeExtensionPackage.unpack(zip, into: stage) }
            try await replaceInstalled(item, with: stage)
        } catch {
            try? fileManager.removeItem(at: stage)
            noteError(Self.describe(error), for: item.id)
        }
    }

    // MARK: - Questions

    /// Asks one question at a time, as a sheet on the key window, so a
    /// prompt never blocks the whole app the way a modal alert would.
    private func ask(title: String, detail: String, icon: NSImage?, confirm: String) async -> Bool {
        let previous = question
        let task = Task { @MainActor () -> Bool in
            _ = await previous?.value
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            if let icon { alert.icon = icon }
            alert.addButton(withTitle: confirm)
            alert.addButton(withTitle: String(localized: "browser.extensions.cancel", defaultValue: "Cancel"))
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
                return alert.runModal() == .alertFirstButtonReturn
            }
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        question = task
        return await task.value
    }

    fileprivate func askForRuntimeAccess(_ context: WKWebExtensionContext, detail: String) async -> Bool {
        await ask(
            title: String(
                format: String(localized: "browser.extensions.moreAccess.title", defaultValue: "“%@” asks for more access"),
                context.webExtension.displayName ?? context.uniqueIdentifier
            ),
            detail: detail,
            icon: context.webExtension.icon(for: CGSize(width: 64, height: 64)),
            confirm: String(localized: "browser.extensions.moreAccess.confirm", defaultValue: "Allow")
        )
    }

    /// A readable summary of the access an extension asks for.
    static func describeAccess(_ found: WKWebExtension) -> String {
        var lines: [String] = []
        let patterns = found.requestedPermissionMatchPatterns
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            lines.append(String(localized: "browser.extensions.access.allSites", defaultValue: "Read and change all your data on all websites"))
        } else if !patterns.isEmpty {
            let hosts = Set(patterns.compactMap(\.host).filter { !$0.isEmpty }).sorted()
            lines.append(String(
                format: String(localized: "browser.extensions.access.someSites", defaultValue: "Read and change your data on: %@"),
                hosts.joined(separator: ", ")
            ))
        }
        let permissions = found.requestedPermissions.map(\.rawValue).sorted()
        if !permissions.isEmpty {
            lines.append(String(
                format: String(localized: "browser.extensions.access.permissions", defaultValue: "Permissions: %@"),
                permissions.joined(separator: ", ")
            ))
        }
        if lines.isEmpty {
            return String(localized: "browser.extensions.access.none", defaultValue: "It does not ask for special access.")
        }
        return lines.map { "• " + $0 }.joined(separator: "\n")
    }

    private static func accessIsSubset(_ found: WKWebExtension, of item: BrowserExtensionInstallation) -> Bool {
        Set(found.requestedPermissions.map(\.rawValue)).isSubset(of: Set(item.grantedPermissions))
            && Set(found.requestedPermissionMatchPatterns.map(\.string)).isSubset(of: Set(item.grantedMatchPatterns))
    }

    static func describe(_ error: Error) -> String {
        guard let failure = error as? ChromeExtensionPackage.Failure else { return error.localizedDescription }
        switch failure {
        case .notAnExtensionID:
            return String(localized: "browser.extensions.error.notAnID", defaultValue: "That is not a Chrome Web Store link or extension ID.")
        case .download(let status):
            return String(
                format: String(localized: "browser.extensions.error.download", defaultValue: "The Chrome Web Store returned HTTP %ld."),
                status
            )
        case .empty:
            return String(localized: "browser.extensions.error.empty", defaultValue: "The Chrome Web Store has no download for that extension.")
        case .notCRX3, .unpack:
            return String(localized: "browser.extensions.error.invalidPackage", defaultValue: "The extension package is invalid or unsafe.")
        case .signatureInvalid, .publisherSignatureMissing:
            return String(localized: "browser.extensions.error.signature", defaultValue: "The extension's signature could not be verified.")
        }
    }

    // MARK: - Pages

    /// State for `cmux://extensions`.
    func managerSnapshot() -> ChromeExtensionsManagerPage.Snapshot {
        let running = Set(controllers.values.flatMap { $0.contexts.keys })
        let rows = installed.map { item in
            ChromeExtensionsManagerPage.Row(
                id: item.id,
                name: item.name,
                version: item.version,
                enabled: item.enabled,
                running: running.contains(item.id),
                fromStore: item.fromStore,
                hasOptions: controllers.values.contains { $0.contexts[item.id]?.optionsPageURL != nil },
                permissions: item.grantedMatchPatterns + item.grantedPermissions,
                errors: errors[item.id] ?? []
            )
        }
        return .init(supported: true, busy: busyID, lastError: lastError, extensions: rows)
    }

    func handleManagerRequest(_ request: ChromeExtensionsManagerPage.Request, from webView: WKWebView) {
        managerPages.add(webView)
        switch request {
        case .snapshot:
            break
        case .install(let text):
            installStoreExtension(from: text)
        case .loadUnpacked:
            installUnpacked()
        case .setEnabled(let id, let enabled):
            setEnabled(id, enabled)
        case .remove(let id):
            remove(id)
        case .reload(let id):
            reload(id)
        case .openOptions(let id):
            openOptions(id)
        case .openStore:
            if let panel = BrowserExtensionPageBridge.panel(for: webView) { openStore(from: panel) }
        }
    }

    func iconPNG(for id: String) -> Data? {
        for controller in controllers.values {
            if let image = controller.contexts[id]?.webExtension.icon(for: CGSize(width: 64, height: 64)),
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                return rep.representation(using: .png, properties: [:])
            }
        }
        return nil
    }

    func didPlaceStoreButton(in webView: WKWebView) {
        storePages.add(webView)
        pushState(to: webView, isStorePage: true)
    }

    private func pushStateToPages() {
        for webView in managerPages.allObjects where webView.url.map(ChromeExtensionsManagerPage.isManagerPageURL) == true {
            pushState(to: webView, isStorePage: false)
        }
        for webView in storePages.allObjects where webView.url.map(ChromeWebStorePage.isStorePage) == true {
            pushState(to: webView, isStorePage: true)
        }
    }

    private func pushState(to webView: WKWebView, isStorePage: Bool) {
        if isStorePage {
            let state = ChromeWebStorePage.State(installed: installed.map(\.id), busy: busyID)
            webView.evaluateJavaScript(
                ChromeWebStorePage.stateUpdateScript(state),
                in: nil,
                in: BrowserExtensionPageBridge.storeWorld,
                completionHandler: nil
            )
        } else if let data = try? JSONEncoder().encode(managerSnapshot()), let json = String(data: data, encoding: .utf8) {
            webView.evaluateJavaScript(
                "window.__cmuxExtensionsPageRender && window.__cmuxExtensionsPageRender(\(json));",
                in: nil,
                in: .page,
                completionHandler: nil
            )
        }
    }

    // MARK: - Storage

    private func save() {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(installed).write(to: metadataURL, options: [.atomic])
    }

    private func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    private func storeKey(for store: WKWebsiteDataStore) -> String {
        store.identifier?.uuidString ?? "default"
    }

    private func controller(for store: WKWebsiteDataStore) -> Controller {
        let key = storeKey(for: store)
        if let existing = controllers[key] { return existing }
        let configuration = store.identifier.map { WKWebExtensionController.Configuration(identifier: $0) } ?? .default()
        configuration.defaultWebsiteDataStore = store
        let webViewConfiguration = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        webViewConfiguration.websiteDataStore = store
        // Extension pages and service workers must present the same identity
        // as browser tabs. WebKit gives workers the user agent of the last
        // page that loaded and, when it differs, stops them without starting
        // them again, which leaves popups such as Bitwarden's waiting forever.
        webViewConfiguration.applicationNameForUserAgent = BrowserUserAgentPolicy.system.safariApplicationName
        configuration.webViewConfiguration = webViewConfiguration
        let controller = Controller(owner: self, configuration: configuration)
        controllers[key] = controller
        if controllers.count == 1 {
            checkForUpdatesIfDue()
        }
        return controller
    }

    private static func detached(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}

// MARK: - Controller delegate

@available(macOS 15.4, *)
@MainActor
private final class Controller: NSObject, WKWebExtensionControllerDelegate {
    unowned let owner: BrowserExtensions
    let controller: WKWebExtensionController
    let window: BrowserExtensionWindow
    var contexts: [String: WKWebExtensionContext] = [:]
    var loading: Set<String> = []
    private(set) var adapters: [UUID: BrowserExtensionTab] = [:]
    private var order: [UUID] = []
    private var observations: [UUID: [AnyCancellable]] = [:]

    init(owner: BrowserExtensions, configuration: WKWebExtensionController.Configuration) {
        self.owner = owner
        controller = WKWebExtensionController(configuration: configuration)
        window = BrowserExtensionWindow()
        super.init()
        window.owner = self
        controller.delegate = self
        controller.didOpenWindow(window)
    }

    var orderedTabs: [BrowserExtensionTab] { order.compactMap { adapters[$0] } }

    var activeTab: BrowserExtensionTab? {
        if let id = owner.focusedPanelID, let tab = adapters[id] { return tab }
        return orderedTabs.last
    }

    func register(_ panel: BrowserPanel) {
        if let existing = adapters[panel.id] {
            existing.panel = panel
            return
        }
        let adapter = BrowserExtensionTab(panel: panel, owner: self)
        adapters[panel.id] = adapter
        order.append(panel.id)
        controller.didOpenTab(adapter)
        let id = panel.id
        let changed: (WKWebExtension.TabChangedProperties) -> Void = { [weak self] properties in
            guard let self, let adapter = self.adapters[id] else { return }
            self.controller.didChangeTabProperties(properties, for: adapter)
        }
        observations[id] = [
            panel.$pageTitle.dropFirst().removeDuplicates().sink { _ in changed(.title) },
            panel.$currentURL.dropFirst().removeDuplicates().sink { _ in changed(.URL) },
            panel.$isLoading.dropFirst().removeDuplicates().sink { _ in changed(.loading) },
        ]
    }

    func unregister(panelID: UUID) {
        observations[panelID] = nil
        order.removeAll { $0 == panelID }
        if let adapter = adapters.removeValue(forKey: panelID) {
            controller.didCloseTab(adapter, windowIsClosing: false)
        }
    }

    func didActivate(panelID: UUID, previous: UUID?) {
        guard let tab = adapters[panelID] else { return }
        controller.didActivateTab(tab, previousActiveTab: previous.flatMap { adapters[$0] })
    }

    func unload(id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        owner.stopObservingErrors(of: context)
        try? controller.unload(context)
        owner.objectWillChange.send()
    }

    /// Opens a browser tab beside the active one and returns its adapter.
    func openTab(url: URL, focus: Bool) -> BrowserExtensionTab? {
        guard let anchor = activeTab?.panel ?? orderedTabs.last?.panel,
              let app = AppDelegate.shared,
              let workspace = app.workspaceContainingPanel(panelId: anchor.id, preferredWorkspaceId: anchor.workspaceId)?.workspace,
              let pane = workspace.paneId(forPanelId: anchor.id),
              let panel = workspace.newBrowserSurface(
                  inPane: pane,
                  url: url,
                  focus: focus,
                  preferredProfileID: anchor.profileID
              ) else { return nil }
        register(panel)
        return adapters[panel.id]
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        openTab(url: configuration.url ?? URL(string: "about:blank")!, focus: configuration.shouldBeActive)
    }

    /// cmux has no separate extension windows: a new window's URLs open as
    /// tabs beside the active one.
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        for (index, url) in configuration.tabURLs.enumerated() {
            _ = openTab(url: url, focus: index == 0 && configuration.shouldBeFocused)
        }
        return window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard let url = extensionContext.optionsPageURL else { return }
        _ = openTab(url: url, focus: true)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let detail = String(
            format: String(localized: "browser.extensions.access.permissions", defaultValue: "Permissions: %@"),
            permissions.map(\.rawValue).sorted().joined(separator: ", ")
        )
        return await owner.askForRuntimeAccess(extensionContext, detail: detail) ? (permissions, nil) : ([], nil)
    }

    /// WebKit asks this whenever an extension reaches for a page outside its
    /// granted hosts, often with no user action. Chrome never prompts here:
    /// an extension has its manifest hosts, activeTab after a click, and
    /// whatever it obtained through permissions.request. Deny.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let all = matchPatterns.contains { $0.matchesAllHosts || $0.matchesAllURLs }
        let detail = all
            ? String(localized: "browser.extensions.access.allSites", defaultValue: "Read and change all your data on all websites")
            : String(
                format: String(localized: "browser.extensions.access.someSites", defaultValue: "Read and change your data on: %@"),
                matchPatterns.map(\.string).sorted().joined(separator: ", ")
            )
        return await owner.askForRuntimeAccess(extensionContext, detail: detail) ? (matchPatterns, nil) : ([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        owner.objectWillChange.send()
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        let panel = (action.associatedTab as? BrowserExtensionTab)?.panel ?? activeTab?.panel
        owner.presentPopup(action, extensionID: context.uniqueIdentifier, panel: panel)
    }
}

// MARK: - Tab and window adapters

@available(macOS 15.4, *)
@MainActor
private final class BrowserExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var owner: Controller?

    private var nsWindow: NSWindow? {
        owner?.activeTab?.panel?.webView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { owner?.orderedTabs ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { owner?.activeTab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = nsWindow else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null }

    func focus(for context: WKWebExtensionContext) async throws {
        nsWindow?.makeKeyAndOrderFront(nil)
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserExtensionTab: NSObject, WKWebExtensionTab {
    weak var panel: BrowserPanel?
    unowned let owner: Controller

    init(panel: BrowserPanel, owner: Controller) {
        self.panel = panel
        self.owner = owner
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner.window }
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        owner.orderedTabs.firstIndex { $0 === self } ?? NSNotFound
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { panel?.webView }
    func title(for context: WKWebExtensionContext) -> String? { panel?.pageTitle }
    func url(for context: WKWebExtensionContext) -> URL? { panel?.webView.url ?? panel?.currentURL }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(panel?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { owner.activeTab === self }
    func isPinned(for context: WKWebExtensionContext) -> Bool { false }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { panel?.isPlayingAudio == true }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(panel?.webView.pageZoom ?? 1) }
    func size(for context: WKWebExtensionContext) -> CGSize { panel?.webView.bounds.size ?? .zero }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws {
        panel?.webView.pageZoom = CGFloat(zoomFactor)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        panel?.navigate(to: url)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws { _ = panel?.reload() }
    func goBack(for context: WKWebExtensionContext) async throws { panel?.goBack() }
    func goForward(for context: WKWebExtensionContext) async throws { panel?.goForward() }

    func activate(for context: WKWebExtensionContext) async throws {
        guard let panel,
              let located = AppDelegate.shared?.workspaceContainingPanel(panelId: panel.id, preferredWorkspaceId: panel.workspaceId)
        else { return }
        located.workspace.focusPanel(panel.id)
    }

    /// Closes this browser tab only, never the window around it.
    func close(for context: WKWebExtensionContext) async throws {
        guard let panel,
              let located = AppDelegate.shared?.workspaceContainingPanel(panelId: panel.id, preferredWorkspaceId: panel.workspaceId)
        else { return }
        _ = located.workspace.closePanel(panel.id)
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext) async throws -> NSImage? {
        guard let webView = panel?.webView else { return nil }
        return try await webView.takeSnapshot(configuration: configuration)
    }
}

@available(macOS 15.4, *)
@MainActor
private final class BrowserExtensionPopoverDelegate: NSObject, NSPopoverDelegate {
    static let shared = BrowserExtensionPopoverDelegate()
    weak var action: WKWebExtension.Action?

    func popoverDidClose(_ notification: Notification) {
        action?.closePopup()
        action = nil
    }
}

final class WeakView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

// MARK: - Page bridges

/// Script, message, and scheme handlers for cmux-owned pages: the Web Store
/// install button and `cmux://extensions`.
@available(macOS 15.4, *)
@MainActor
final class BrowserExtensionPageBridge: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKURLSchemeHandler {
    static let shared = BrowserExtensionPageBridge()
    static let storeWorld = WKContentWorld.world(name: ChromeWebStorePage.contentWorldName)
    private static var installedKey: UInt8 = 0

    static func install(on configuration: WKWebViewConfiguration) {
        if configuration.urlSchemeHandler(forURLScheme: ChromeExtensionsManagerPage.scheme) == nil {
            configuration.setURLSchemeHandler(shared, forURLScheme: ChromeExtensionsManagerPage.scheme)
        }
        let controller = configuration.userContentController
        guard objc_getAssociatedObject(controller, &installedKey) == nil else { return }
        objc_setAssociatedObject(controller, &installedKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // Isolated world: store page JavaScript cannot reach this handler.
        controller.add(shared, contentWorld: storeWorld, name: ChromeWebStorePage.messageHandlerName)
        controller.addUserScript(WKUserScript(
            source: ChromeWebStorePage.userScriptSource(labels: .init(
                add: String(localized: "browser.extensions.store.add", defaultValue: "Add to cmux"),
                adding: String(localized: "browser.extensions.store.adding", defaultValue: "Adding…"),
                added: String(localized: "browser.extensions.store.added", defaultValue: "Added to cmux")
            )),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: storeWorld
        ))
        // Page world, but every message is checked against the frame's
        // security origin, which web content cannot forge.
        controller.addScriptMessageHandler(shared, contentWorld: .page, name: ChromeExtensionsManagerPage.messageHandlerName)
    }

    static func panel(for webView: WKWebView) -> BrowserPanel? {
        AppDelegate.shared?.allBrowserPanelsForInspectorWindowClose().first { $0.webView === webView }
    }

    // Web Store button.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == ChromeWebStorePage.messageHandlerName,
              message.frameInfo.isMainFrame,
              let webView = message.webView,
              let url = webView.url,
              ChromeWebStorePage.isStorePage(url),
              let body = message.body as? [String: Any] else { return }
        let extensions = BrowserExtensions.shared
        extensions.didPlaceStoreButton(in: webView)
        // The id is read from the tab's own address, never from the page.
        if body["add"] != nil, let id = ChromeWebStorePage.extensionID(onStorePage: url) {
            extensions.installStoreExtension(from: id)
        }
    }

    // cmux://extensions requests.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let origin = message.frameInfo.securityOrigin
        guard message.name == ChromeExtensionsManagerPage.messageHandlerName,
              message.frameInfo.isMainFrame,
              origin.protocol.lowercased() == ChromeExtensionsManagerPage.scheme,
              origin.host.lowercased() == ChromeExtensionsManagerPage.host,
              let webView = message.webView,
              let request = ChromeExtensionsManagerPage.Request(messageBody: message.body) else {
            replyHandler(nil, "denied")
            return
        }
        let extensions = BrowserExtensions.shared
        extensions.handleManagerRequest(request, from: webView)
        guard let data = try? JSONEncoder().encode(extensions.managerSnapshot()),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            replyHandler(nil, "encoding")
            return
        }
        replyHandler(object, nil)
    }

    // cmux://extensions and its icons.
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, ChromeExtensionsManagerPage.isManagerPageURL(url) else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let body: Data
        let contentType: String
        if let id = ChromeExtensionsManagerPage.iconExtensionID(for: url) {
            guard let png = BrowserExtensions.shared.iconPNG(for: id) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            body = png
            contentType = "image/png"
        } else if url.path.isEmpty || url.path == "/" {
            let language = Locale.preferredLanguages.first ?? "en"
            let direction = Locale.Language(identifier: language).characterDirection == .rightToLeft ? "rtl" : "ltr"
            body = Data(ChromeExtensionsManagerPage.html(
                strings: Self.pageStrings,
                languageCode: language,
                layoutDirection: direction
            ).utf8)
            contentType = "text/html; charset=utf-8"
        } else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        var headers = ChromeExtensionsManagerPage.responseHeaders
        headers["Content-Type"] = contentType
        headers["Content-Length"] = String(body.count)
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private static var pageStrings: ChromeExtensionsManagerPage.Strings {
        .init(
            title: String(localized: "browser.extensions.page.title", defaultValue: "Extensions"),
            subtitle: String(localized: "browser.extensions.page.subtitle", defaultValue: "Chrome extensions run in cmux browser tabs on macOS 15.4 or later."),
            installPlaceholder: String(localized: "browser.extensions.page.installPlaceholder", defaultValue: "Chrome Web Store link or extension ID"),
            installButton: String(localized: "browser.extensions.page.install", defaultValue: "Add"),
            loadUnpacked: String(localized: "browser.extensions.page.loadUnpacked", defaultValue: "Load Unpacked…"),
            openStore: String(localized: "browser.extensions.page.openStore", defaultValue: "Open Chrome Web Store"),
            empty: String(localized: "browser.extensions.page.empty", defaultValue: "No extensions installed."),
            unsupported: String(localized: "browser.extensions.page.unsupported", defaultValue: "Extensions require macOS 15.4 or later."),
            enabled: String(localized: "browser.extensions.page.enabled", defaultValue: "On"),
            options: String(localized: "browser.extensions.page.options", defaultValue: "Options"),
            reload: String(localized: "browser.extensions.page.reload", defaultValue: "Reload"),
            remove: String(localized: "browser.extensions.remove.confirm", defaultValue: "Remove"),
            fromStore: String(localized: "browser.extensions.page.fromStore", defaultValue: "Chrome Web Store"),
            unpacked: String(localized: "browser.extensions.page.unpacked", defaultValue: "Unpacked"),
            notRunning: String(localized: "browser.extensions.page.notRunning", defaultValue: "Not running"),
            permissions: String(localized: "browser.extensions.page.permissions", defaultValue: "Access"),
            noPermissions: String(localized: "browser.extensions.access.none", defaultValue: "It does not ask for special access."),
            installing: String(localized: "browser.extensions.store.adding", defaultValue: "Adding…"),
            id: String(localized: "browser.extensions.page.id", defaultValue: "ID")
        )
    }
}
