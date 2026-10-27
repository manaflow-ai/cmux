import AppKit
import CmuxNextCompatAppKit
import CmuxNextWakeups
import CmuxNextPages
import CmuxNextDesign
import CmuxNextActions
import CmuxNextDaemon
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Target resolution for workspace, group, window, and sidebar handlers.
/// Each throws an `ActionFailure` instead of silently doing nothing.
extension AppActionContext {
    var store: DaemonStore { services.activeDaemon.store }
    var activeWindow: WindowController? { services.windows.active }

    /// Throws unless the daemon serves `capability`.
    func require(_ capability: String) throws {
        let daemon = services.activeDaemon
        guard daemon.supports(capability) else { throw ActionFailure(message: daemon.missingCapabilityMessage(capability)) }
    }

    /// The targeted workspace (target, `workspace` argument) or the one the
    /// active window shows.
    func workspace(_ invocation: ActionInvocation) throws -> (model: WorkspaceModel, key: WorkspaceKey) {
        guard let model = scope(invocation).workspace else { throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn) }
        guard let key = model.key else { throw ActionFailure.needsDaemonCapability("workspace-registry-v1") }
        return (model, key)
    }

    /// The active window's workspaces in sidebar order (ungrouped first,
    /// then each group). Each window lists only its own workspaces.
    var sidebarOrder: [WorkspaceModel] {
        let all = store.sidebarSections.flatMap(\.workspaces)
        guard let window = activeWindow else { return all }
        let members = Set(services.windows.registry.members(of: window.state.id))
        return all.filter { members.contains($0.id) }
    }

    /// The targeted workspace group (target, `group` argument), else the
    /// group of the targeted or shown workspace. Workspace groups are
    /// personal (the home session's); without personal state there are none.
    func group(_ invocation: ActionInvocation) throws -> WorkspaceGroupModel {
        guard usesPersonalGroups else {
            throw ActionFailure(message: services.machines.local.personalStateUnavailableReason)
        }
        return try personalGroup(invocation)
    }

    /// The window named by the target or `window` argument (`WindowState.id`),
    /// else the active window.
    func window(_ invocation: ActionInvocation) throws -> WindowController {
        let ref = [invocation.target, invocation["window"]?.targetValue].compactMap { $0 }.first { $0.kind == .window }
        guard let ref else {
            guard let active = activeWindow else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
            return active
        }
        guard let controller = services.windows.controllerBuildingIfWaiting(for: ref.id) else { // a named target acts in it
            throw ActionFailure.notFound(RefusalStrings.noWindow(ref.id))
        }
        return controller
    }

    /// The active window's sidebar, which turns intents into daemon commands
    /// with an optimistic sidebar update (the same path as clicks and drags).
    func sidebar() throws -> SidebarBridge {
        guard let sidebar = activeWindow?.sidebar else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
        return sidebar
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Opens `url`: an http(s) link through the link router on this turn; any other URL in its app off the main
    /// thread (cx-050n), once Launch Services names that app on the system lane. A URL with no scheme is refused at
    /// once, and one no app opens fails the action, so a script, the CLI or an agent gets the failure.
    func open(_ url: URL) -> ActionEffect {
        let failure = RefusalStrings.couldNotOpen(url.absoluteString)
        guard let scheme = url.scheme?.lowercased() else { return .refused(failure) }
        if scheme == "http" || scheme == "https" {
            LinkRouter.shared.open(url)
            return .done
        }
        // action-wait-allow: which app opens the URL is known only when Launch Services answers on the system lane; then it opens.
        return .waiting(.externalProcess, openWork(url))
    }

    /// The open of `url` in its app: asks Launch Services for the app on the system lane, then opens off the main
    /// thread. The work answers nil when it opened, else the failure (no app opens it, or the open failed).
    func openWork(_ url: URL) -> @MainActor () async -> ActionWorkFailure? {
        Self.openWork(url, queries: services.workspaceQueries)
    }

    /// ``openWork(_:)`` over `queries` (tests pass ones over a fake Launch Services).
    static func openWork(_ url: URL, queries: WorkspaceQueries) -> @MainActor () async -> ActionWorkFailure? {
        return {
            let failure = ActionWorkFailure(RefusalStrings.couldNotOpen(url.absoluteString))
            let app = (try? await queries.value(WorkspaceQuery<URL?>.defaultApplication(toOpen: url), priority: .userBlocking)) ?? nil
            guard app != nil else { return failure }
            // A reply that never comes did not open.
            let opened = (try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
                NSWorkspace.shared.openInBackground(url) { continuation.resume(returning: $0) }
            }) ?? false
            return opened ? nil : failure
        }
    }

    /// Brings the app forward unless launched with `CMUX_NEXT_NO_ACTIVATE=1`
    /// or the run may not change this client's view.
    func activateApp() {
        guard ActionRunScope.viewChangeAllowed() else { return }
        WindowActivation.activateApp()
    }
}
