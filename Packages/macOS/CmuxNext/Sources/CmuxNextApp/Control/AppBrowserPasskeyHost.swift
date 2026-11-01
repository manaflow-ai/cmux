import AppKit
import CmuxNextControl

/// The app side of the passkey hand-off (plans/cmux-next/agent-browser-passkey-DESIGN.md 3.2):
/// whether a browser tab is in front of the person, revealing it after their
/// banner click, and the banner itself.
@MainActor
final class AppBrowserPasskeyHost: BrowserPasskeyHost, Sendable {
    /// Banner ids of passkey requests carry this prefix; the banner click routes them here.
    nonisolated static let bannerPrefix = "cmux-passkey-"

    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    /// The request id a passkey banner names, nil for any other banner.
    nonisolated static func requestID(banner id: String) -> String? {
        id.hasPrefix(bannerPrefix) ? String(id.dropFirst(bannerPrefix.count)) : nil
    }

    func isInFront(tabID: String) async -> Bool {
        guard NSApp.isActive, let services, let (tab, pane) = services.locateTabOnAnyMachine(tabID),
              let controller = services.paneController(for: pane) else { return false }
        return controller.selectedTab?.id == tab.id && controller.view.window?.isKeyWindow == true
    }

    func reveal(tabID: String) async throws {
        guard let services, services.locateTabOnAnyMachine(tabID) != nil else {
            throw ControlError(code: "not_found", message: "No tab \(tabID)")
        }
        // The person clicked the request: a person's view change.
        let context = AppActionContext(services: services)
        TabHandlers.reveal(tabID: tabID, ctx: context)
        if !services.environment.noActivate { NSApp.activate() }
        if let (_, pane) = services.locateTabOnAnyMachine(tabID), let window = services.paneController(for: pane)?.view.window {
            window.makeKeyAndOrderFront(nil)
        }
        // WebKit starts WebAuthn only in a focused document (`Document::hasFocus`).
        services.cache.existingBrowser(tabID)?.tab.setFocused(true)
    }

    func post(_ request: BrowserPasskeyRequest) async {
        guard let services else { return }
        let title = String(format: String(localized: "browserPasskey.banner.title", defaultValue: "%@ needs your passkey",
                                          table: "NotificationsPanel", bundle: .module), request.agent)
        let body = String(format: String(localized: "browserPasskey.banner.body", defaultValue: "%@: click to show the page and use Touch ID.",
                                         table: "NotificationsPanel", bundle: .module), request.site)
        services.notifications.desktop.post(id: Self.bannerPrefix + request.id, title: title, body: body, surface: nil,
                                            workspace: nil, defaultSound: true)
    }

    func withdraw(_ id: String) async {
        services?.notifications.desktop.withdraw([Self.bannerPrefix + id])
    }
}
