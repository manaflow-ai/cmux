public import CmuxNextActions
public import CmuxNextApps
import CmuxNextDesign
public import AppKit

/// Toggle Custom Sidebar (`sidebar.custom.toggle`, Lawrence 2026-11-09: "make it easier to toggle the
/// custom sidebar"). One press shows or hides the user's custom sidebar, the `local/customize` app,
/// from the palette (checked while shown), its shortcut, the sidebar's Options menu (Show, Hide or
/// Create Custom Sidebar) and `cmux sidebar toggle-custom`. It flips the app's hidden flag, the one
/// Hide App writes and the supervisor keeps across relaunches, so the section, the row decorations
/// and the hover card go and come back together. With no installed app it writes the starter, which
/// the daemon installs by itself.
@MainActor
public struct CustomSidebarToggle {
    /// The action.
    public static let id: ActionID = "sidebar.custom.toggle"
    /// The user's customization app.
    static let appID = "local/customize"

    private let apps: @MainActor () -> AppsClient?
    private let folder: CustomizeFolder?
    private let window: @MainActor () -> NSWindow?

    /// - Parameters:
    ///   - apps: The app supervisor's client; nil makes a press do nothing.
    ///   - environment: The process environment, which names the customize folder the daemon watches
    ///     (``CustomizeFolder/init(environment:)``); with no home folder there is none to write the starter into.
    ///   - window: The window the starter's toast shows in.
    public init(apps: @escaping @MainActor () -> AppsClient?, environment: [String: String], window: @escaping @MainActor () -> NSWindow?) {
        self.apps = apps
        folder = CustomizeFolder(environment: environment)
        self.window = window
    }

    /// Binds the action, its menu titles and its palette check.
    public func bind(into registry: ActionRegistry) {
        let apps = apps, folder = folder, window = window
        let state = { @MainActor in CustomSidebarState(record: apps()?.app(Self.appID)) }
        registry.bindEffect(Self.id, unavailable: { apps()?.unavailableReason?.text }) { invocation in
            guard let client = apps() else { return .done }
            if let change = state().toggleChange {
                let origin = AppOrigin(rawValue: invocation.origin.rawValue) ?? .script
                // The client shows the change at once (a pending intent) and drops it if the supervisor refuses.
                return .applied(result: {
                    do throws(AppsClientError) {
                        try await client.set(Self.appID, change, origin: origin)
                        return .success([:])
                    } catch {
                        return .failure(ActionWorkFailure(error.description))
                    }
                })
            }
            guard let folder else { return .refused(CustomSidebarStrings.noHome) }
            return .applied(result: {
                do {
                    guard try await folder.writeStarter() else {
                        return .failure(ActionWorkFailure(CustomSidebarStrings.unreadable(folder.manifestURL.path(percentEncoded: false))))
                    }
                } catch {
                    return .failure(ActionWorkFailure(CustomSidebarStrings.couldNotCreate(error.localizedDescription)))
                }
                // The daemon watches the folder; a reload shows the new app without waiting for the watch.
                client.reloadLocalApps()
                if let window = window() {
                    _ = CmuxToastCenter.shared.show(CmuxToast(id: "custom-sidebar-created", message: CustomSidebarStrings.created,
                                                              detail: folder.scriptURL.path(percentEncoded: false)), in: window)
                }
                return .success([:])
            })
        }
        ActionTargetTitles.set(Self.id, in: registry) { _ in
            switch state() {
            case .shown: CustomSidebarStrings.hide
            case .hidden: CustomSidebarStrings.show
            case .missing: CustomSidebarStrings.create
            }
        }
        ActionTargetTitles.setPaletteState(Self.id, in: registry) { state() == .shown }
    }
}
