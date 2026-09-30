public import AppKit

extension MockBrowserTab: BrowserExtensionActionHosting {
    public func runExtensionAction(_ id: String, anchor: CGRect) {
        record(.runExtensionAction(id, anchor: anchor))
        if extensionActions.first(where: { $0.id == id })?.hasPopup == true { openExtensionPopup = id }
    }

    public func hideExtensionPopups() {
        record(.hideExtensionPopups)
        openExtensionPopup = nil
    }

    public func showExtensionActionMenu(_ id: String, atScreenPoint point: CGPoint) {
        record(.showExtensionActionMenu(id))
    }

    /// Installs `extensions` (their toolbar actions follow `hasAction` and
    /// `isPinned`) and shows the Extensions button.
    public func installMockExtensions(_ extensions: [BrowserExtensionInfo]) {
        showsExtensionToolbar = true
        extensionBackend.extensions = extensions
        extensionBackend.onChange = { [weak self] in self?.syncMockActions() }
        syncMockActions()
    }

    private func syncMockActions() {
        extensionActions = extensionBackend.extensions.filter { $0.isEnabled && $0.hasAction }.map {
            CEFExtensionAction(id: $0.id, name: $0.name, title: $0.name, isPinned: $0.isPinned, hasPopup: true)
        }
        extensionStore.refresh()
    }
}

/// In-memory extensions for demos and tests. Every management call
/// succeeds unless `refuses` is set.
public final class MockExtensionBackend: BrowserExtensionBackend {
    public var extensions: [BrowserExtensionInfo] = []
    public var commands: [BrowserExtensionCommand] = []
    public var supportsManagement = true
    public var refuses = false
    public private(set) var ranCommands: [BrowserExtensionCommand] = []
    public private(set) var openedOptions: [String] = []
    var onChange: (() -> Void)?

    public init() {}

    public func snapshot() -> (extensions: [BrowserExtensionInfo], commands: [BrowserExtensionCommand])? {
        (extensions, commands)
    }

    public func setEnabled(_ id: String, _ enabled: Bool) -> Bool { change(id) { $0.isEnabled = enabled } }
    public func setPinned(_ id: String, _ pinned: Bool) -> Bool { change(id) { $0.isPinned = pinned } }

    public func uninstall(_ id: String) -> Bool {
        guard !refuses, extensions.contains(where: { $0.id == id }) else { return false }
        extensions.removeAll { $0.id == id }
        onChange?()
        return true
    }

    public func openOptions(_ id: String, from tab: (any BrowserTab)?) -> Bool {
        guard !refuses else { return false }
        openedOptions.append(id)
        return true
    }

    public func loadUnpacked(at path: String) -> Bool {
        guard !refuses else { return false }
        let name = URL(fileURLWithPath: path).lastPathComponent
        extensions.append(BrowserExtensionInfo(id: name, name: name, location: .unpacked, hasAction: true, path: path))
        onChange?()
        return true
    }

    public func runCommand(_ command: BrowserExtensionCommand, in tab: any BrowserTab) -> Bool {
        ranCommands.append(command)
        return !refuses
    }

    private func change(_ id: String, _ body: (inout BrowserExtensionInfo) -> Void) -> Bool {
        guard !refuses, let index = extensions.firstIndex(where: { $0.id == id }) else { return false }
        body(&extensions[index])
        onChange?()
        return true
    }
}
