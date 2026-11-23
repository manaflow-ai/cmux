public import CmuxNextPages
import CmuxNextSettings
public import Foundation

/// What the native App Store asks of its owner: the Rust store's reads, and the person's changes through
/// the same paths the React page and the `app.install` / `app.remove` actions use. The view holds no store
/// logic: every list, listing and section comes from these calls.
@MainActor
public protocol AppStoreOps: AnyObject {
    /// One read-only store op (`apps.catalog.list`, `apps.catalog.get`, `apps.catalog.sections`,
    /// `apps.installed.list`, `apps.updates.list`, `apps.asset.get`) with its arguments.
    func read(_ op: String, args: AppJSON) async throws(AppsClientError) -> AppJSON
    /// Install (`cmux.apps.install`), update (`cmux.apps.update`) or remove (`cmux.apps.uninstall`) `app`
    /// behind the App Store's consent card; the person's click on it makes the call theirs.
    func change(_ kind: AppStoreChangeKind, app: String) async -> AppsStoreChange.Outcome
    /// Hide or show a first-party app (`apps-set hidden`, the person's click).
    func setHidden(_ app: String, hidden: Bool) async throws(AppsClientError)
    /// Opens the app (the host action `app.open`).
    func open(_ app: String)
    /// Opens a link from a listing (its repository) in cmux's browser.
    func openLink(_ url: URL)
    /// Calls `onChange` after the owner's install mirror moves (`apps-changed`), while `owner` lives.
    func observeChanges(owner: AnyObject, _ onChange: @escaping @MainActor () -> Void)
}

/// A change the store's one-click buttons make.
public nonisolated enum AppStoreChangeKind: Sendable, Hashable {
    case install, update, remove

    /// The owner's op.
    var op: String {
        switch self {
        case .install: "cmux.apps.install"
        case .update: "cmux.apps.update"
        case .remove: "cmux.apps.uninstall"
        }
    }
}

/// ``AppStoreOps`` over the apps client (reads, Hide/Show), the App Store's confirming provider (the consent
/// card in front of install, update and remove) and the host's open actions.
@MainActor
public final class AppStoreClientOps: AppStoreOps {
    private let client: AppsClient
    private let changes: any PageProvider
    private let openApp: @MainActor (String) -> Void
    private let openURL: @MainActor (URL) -> Void

    /// - Parameters:
    ///   - client: The apps client (the supervisor connection).
    ///   - changes: The App Store's `cmux.apps.*` provider with its consent card (`PageFactory.appsStoreProvider()`).
    ///   - open: Runs `app.open` for an app id with the person's origin.
    ///   - openLink: Opens a URL in cmux's browser.
    public init(client: AppsClient, changes: any PageProvider, open: @escaping @MainActor (String) -> Void,
                openLink: @escaping @MainActor (URL) -> Void) {
        self.client = client
        self.changes = changes
        openApp = open
        openURL = openLink
    }

    public func read(_ op: String, args: AppJSON) async throws(AppsClientError) -> AppJSON {
        try await client.storeRead(op, args: args)
    }

    public func change(_ kind: AppStoreChangeKind, app: String) async -> AppsStoreChange.Outcome {
        switch kind {
        case .install: return await AppsStoreChange(kind: .install, app: app).send(through: changes)
        case .remove: return await AppsStoreChange(kind: .remove, app: app).send(through: changes)
        case .update:
            let params: AppJSON = ["app": .string(app), "idempotency_key": .string("apps-store-change.\(UUID().uuidString)")]
            do {
                _ = try await changes.call(kind.op, params: params.settingsValue, context: PageCallContext(page: PageDescriptor.apps.id))
                return .done
            } catch let error as PageError where error == .cancelled {
                return .declined
            } catch let error as PageError {
                return .refused(code: error.details?["code"]?.stringValue ?? error.code, message: error.message)
            } catch {
                return .refused(code: "error", message: String(describing: error))
            }
        }
    }

    public func setHidden(_ app: String, hidden: Bool) async throws(AppsClientError) {
        try await client.set(app, .hide(hidden), origin: .user)
    }

    public func open(_ app: String) { openApp(app) }

    public func openLink(_ url: URL) { openURL(url) }

    public func observeChanges(owner: AnyObject, _ onChange: @escaping @MainActor () -> Void) {
        client.observeEvents(owner: owner) { event in
            if case .changed = event { onChange() }
        }
    }
}
