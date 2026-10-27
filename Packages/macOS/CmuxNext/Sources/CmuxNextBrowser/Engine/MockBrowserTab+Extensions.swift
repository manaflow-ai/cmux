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
}

/// In-memory extensions for demos and tests. Every management call
/// answers at once, as the in-process shim does: Chromium accepts it unless
/// `refuses` is set (a refused call is still sent and answers false).
public final class MockExtensionBackend: BrowserExtensionBackend {
    public var extensions: [BrowserExtensionInfo] = []
    public var commands: [BrowserExtensionCommand] = []
    public var supportsManagement = true
    public var refuses = false
    public private(set) var ranCommands: [BrowserExtensionCommand] = []
    public private(set) var openedOptions: [String] = []
    /// Snapshots taken: each is a Chromium round trip in the real backend.
    public private(set) var snapshots = 0
    var onChange: (() -> Void)?

    public init() {}

    public func snapshot() -> (extensions: [BrowserExtensionInfo], commands: [BrowserExtensionCommand])? {
        snapshots += 1
        return (extensions, commands)
    }

    public func setEnabled(_ id: String, _ enabled: Bool, answered: @escaping (Bool) -> Void) -> Bool {
        change(id, answered) { $0.isEnabled = enabled }
    }
    public func setPinned(_ id: String, _ pinned: Bool, answered: @escaping (Bool) -> Void) -> Bool {
        change(id, answered) { $0.isPinned = pinned }
    }
    public func reload(_ id: String, answered: @escaping (Bool) -> Void) -> Bool {
        change(id, answered) { $0.isTerminated = false }
    }
    public var supportsPinnedOrder: Bool { supportsManagement }

    /// Reorders like Chromium: pinned extensions first, in pin order.
    public func movePinned(_ id: String, to index: Int, answered: @escaping (Bool) -> Void) -> Bool {
        guard let from = extensions.firstIndex(where: { $0.id == id && $0.isPinned }) else { return false }
        if !refuses {
            let item = extensions.remove(at: from)
            let pinned = extensions.indices.filter { extensions[$0].isPinned }
            let target = index < pinned.count ? pinned[max(0, index)] : (pinned.last.map { $0 + 1 } ?? 0)
            extensions.insert(item, at: target)
            onChange?()
        }
        answered(!refuses)
        return true
    }

    public func uninstall(_ id: String, answered: @escaping (Bool) -> Void) -> Bool {
        guard extensions.contains(where: { $0.id == id }) else { return false }
        if !refuses {
            extensions.removeAll { $0.id == id }
            onChange?()
        }
        answered(!refuses)
        return true
    }

    public func openOptions(_ id: String, from tab: (any BrowserTab)?, answered: @escaping (Bool) -> Void) -> Bool {
        if !refuses { openedOptions.append(id) }
        answered(!refuses)
        return true
    }

    public func loadUnpacked(at path: String, answered: @escaping (Bool) -> Void) -> Bool {
        if !refuses {
            let name = URL(fileURLWithPath: path).lastPathComponent
            extensions.append(BrowserExtensionInfo(id: name, name: name, location: .unpacked, hasAction: true, path: path))
            onChange?()
        }
        answered(!refuses)
        return true
    }

    public func runCommand(_ command: BrowserExtensionCommand, in tab: any BrowserTab) -> Bool {
        ranCommands.append(command)
        return !refuses
    }

    private func change(_ id: String, _ answered: (Bool) -> Void, _ body: (inout BrowserExtensionInfo) -> Void) -> Bool {
        guard let index = extensions.firstIndex(where: { $0.id == id }) else { return false }
        if !refuses {
            body(&extensions[index])
            onChange?()
        }
        answered(!refuses)
        return true
    }
}
