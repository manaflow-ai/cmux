import AppKit
import WebKit

/// Presents the browser panels owned by one native cmux window to web
/// extensions as one stable browser window.
@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    private weak var support: BrowserWebExtensionSupport?
    private(set) weak var hostWindow: NSWindow?
    private weak var extensionCreationContext: WKWebExtensionContext?
    private var extensionCreatedWindowID: UUID?
    private var extensionCreatedPanelIDs = Set<UUID>()
    private var pendingExtensionCreatedPanelCount = 0
    private var extensionCloseAuthorityRevoked = false

    init(support: BrowserWebExtensionSupport, hostWindow: NSWindow) {
        self.support = support
        self.hostWindow = hostWindow
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let hostWindow else { return [] }
        return support?.orderedTabAdapters(in: hostWindow) ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let hostWindow else { return nil }
        return support?.activeTabAdapter(in: hostWindow)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let hostWindow else { return .normal }
        if hostWindow.styleMask.contains(.fullScreen) {
            return .fullscreen
        }
        if hostWindow.isMiniaturized {
            return .minimized
        }
        if hostWindow.isZoomed {
            return .maximized
        }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        hostWindow?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        hostWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let hostWindow else {
            completionHandler(unavailableWindowError())
            return
        }
        NSApp.activate()
        hostWindow.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard extensionCreationContext === context else {
            completionHandler(NSError(domain: "cmux.webExtension", code: 4))
            return
        }
        guard let appDelegate = AppDelegate.shared,
              let hostWindow,
              let windowID = extensionCreatedWindowID,
              appDelegate.windowForMainWindowId(windowID) === hostWindow,
              let context = appDelegate.contextForMainTerminalWindow(hostWindow),
              context.windowId == windowID,
              context.tabManager.containsOnlyBrowserWebExtensionClosablePanels(),
              appDelegate.existingWindowDock(forWindowId: windowID)?.panels.values
                .allSatisfy({ $0 is BrowserPanel }) != false,
              !extensionCloseAuthorityRevoked,
              let support else {
            completionHandler(unavailableWindowError())
            return
        }
        let livePanelIDs = Set(support.orderedTabAdapters(in: hostWindow).compactMap { $0.panel?.id })
        guard !livePanelIDs.isEmpty,
              livePanelIDs.isSubset(of: extensionCreatedPanelIDs),
              appDelegate.closeMainWindow(windowId: windowID, recordHistory: false) else {
            completionHandler(unavailableWindowError())
            return
        }
        completionHandler(nil)
    }

    func markExtensionCreated(
        by context: WKWebExtensionContext,
        windowID: UUID,
        panelIDs: Set<UUID>
    ) {
        extensionCreationContext = context
        extensionCreatedWindowID = windowID
        extensionCreatedPanelIDs = panelIDs
    }

    func prepareToCreateExtensionPanel(for context: WKWebExtensionContext) -> Bool {
        guard extensionCreationContext === context, !extensionCloseAuthorityRevoked else {
            return false
        }
        pendingExtensionCreatedPanelCount += 1
        return true
    }

    func finishCreatingExtensionPanel(panelID: UUID?, wasPrepared: Bool) {
        guard wasPrepared else { return }
        if pendingExtensionCreatedPanelCount > 0 {
            pendingExtensionCreatedPanelCount -= 1
        }
        if let panelID {
            extensionCreatedPanelIDs.insert(panelID)
        }
    }

    func notePanelAdded(_ panelID: UUID) {
        guard extensionCreationContext != nil,
              !extensionCreatedPanelIDs.contains(panelID) else { return }
        if pendingExtensionCreatedPanelCount > 0 {
            pendingExtensionCreatedPanelCount -= 1
            extensionCreatedPanelIDs.insert(panelID)
        } else {
            extensionCloseAuthorityRevoked = true
        }
    }

    func notePanelRemoved(_ panelID: UUID) {
        extensionCreatedPanelIDs.remove(panelID)
    }

    func revokeExtensionCloseAuthority() {
        extensionCloseAuthorityRevoked = true
    }

    func applyInitialConfiguration(
        requestedFrame: CGRect,
        windowState: WKWebExtension.WindowState
    ) {
        guard let hostWindow else { return }
        var frame = hostWindow.frame
        let minimumSize = CmuxMainWindow.minimumContentSize
        let maximumSize = hostWindow.screen?.visibleFrame.size
            ?? NSScreen.main?.visibleFrame.size
            ?? NSSize(width: 1440, height: 900)
        if requestedFrame.origin.x.isFinite {
            frame.origin.x = requestedFrame.origin.x
        }
        if requestedFrame.origin.y.isFinite {
            frame.origin.y = requestedFrame.origin.y
        }
        if requestedFrame.width.isFinite {
            frame.size.width = min(
                max(requestedFrame.width, minimumSize.width),
                max(maximumSize.width, minimumSize.width)
            )
        }
        if requestedFrame.height.isFinite {
            frame.size.height = min(
                max(requestedFrame.height, minimumSize.height),
                max(maximumSize.height, minimumSize.height)
            )
        }
        if frame != hostWindow.frame {
            hostWindow.setFrame(frame, display: true)
        }

        switch windowState {
        case .normal:
            break
        case .minimized:
            hostWindow.miniaturize(nil)
        case .maximized:
            if !hostWindow.isZoomed {
                hostWindow.zoom(nil)
            }
        case .fullscreen:
            if !hostWindow.styleMask.contains(.fullScreen) {
                hostWindow.toggleFullScreen(nil)
            }
        @unknown default:
            break
        }
    }

    private func unavailableWindowError() -> NSError {
        NSError(
            domain: "cmux.webExtension",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: String(
                localized: "browser.webExtension.error.noBrowserWindow",
                defaultValue: "No browser window is available."
            )]
        )
    }
}
