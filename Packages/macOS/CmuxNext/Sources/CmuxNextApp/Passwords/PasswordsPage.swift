import AppKit
import CmuxNextActions
import CmuxNextIcons
import CmuxNextPages
import Foundation

extension PageDescriptor {
    /// The Passwords page (plans/cmux-next/passwords.md 1.4): cmux-page://cmux.passwords/. It
    /// calls only its own namespace; it runs no registry action and no native op.
    static let passwords = PageDescriptor(id: "cmux.passwords", resource: "passwords", namespaces: ["cmux.passwords."],
                                          ownsSearchField: true)
}

extension InternalPageID {
    static let passwords = InternalPageID(rawValue: "passwords")
}

/// Owns the Passwords page: a React page tab (one per window) whose `cmux.passwords.*` ops the
/// app serves from one ``PasswordStore``. User-only: it opens from the palette (`passwords.open`,
/// person-only), and nothing on the control socket, the CLI or MCP reaches its ops.
@MainActor
final class PasswordsPageService: InternalPageProvider {
    private weak var services: AppServices?
    /// The store every Passwords tab and the browser profile delete sheet read.
    let store: any PasswordStore

    init(services: AppServices, store: (any PasswordStore)? = nil) {
        self.services = services
        self.store = store ?? Self.makeStore(services)
    }

    /// The DEBUG sample store when `CMUX_NEXT_PASSWORDS_SAMPLE=1` (tagged DEV dogfood), else
    /// Chromium's store. Release builds have no sample store at all.
    static func makeStore(_ services: AppServices) -> any PasswordStore {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_NEXT_PASSWORDS_SAMPLE"] == "1" { return SamplePasswordStore() }
        #endif
        return ChromiumPasswordStore(engine: { [weak services] in services?.cache?.cef })
    }

    func open(focus: Bool) throws {
        guard let services, let window = services.windows.active, services.pages.show(.passwords, in: window, focus: focus) != nil else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
    }

    var page: InternalPageID { .passwords }
    var title: String { PasswordStrings.pageTitle }
    var symbol: String { "key" }
    var icon: IconName? { .securityLock }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let provider = PasswordsPageProvider(
            store: store, profiles: { [weak services] in Self.profiles(services) },
            confirmations: DialogPageConfirmationPresenter(), authenticator: LocalDeviceOwnerAuthenticator(),
            secrets: NativePasswordSecretSurface())
        let routes = [PageRoute(prefix: "cmux.passwords.", provider: provider)]
        guard let page = PageWebView(descriptor: .passwords, routes: routes) else { return NSView() }
        provider.anchor = { [weak page] in page }
        return page
    }

    /// The browser profiles in sidebar order (the default profile first when it leads).
    static func profiles(_ services: AppServices?) -> [PasswordsPageProvider.Profile] {
        guard let profiles = services?.browserProfiles else { return [] }
        return profiles.ordered.map { .init(id: $0.id, name: profiles.displayName($0.id)) }
    }
}
