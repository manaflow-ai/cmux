package import CmuxNextBrowser
package import CmuxNextDaemonService
package import Foundation

/// Workbench operations needed to place a sign-in page beside its source pane.
@MainActor
package protocol ChatMachineSignInHost: AnyObject {
    func signInDaemon(for chat: String) -> DaemonService?
    func signInLifetime(for chat: String) -> @MainActor () -> Bool
    func signInProfile() -> (wire: String?, engine: BrowserProfileID)
    func placeSignInTab(_ make: @escaping @MainActor (_ adopt: @MainActor (any BrowserTab, String?) -> Bool) -> Bool) -> Bool
    func openSignInPage(_ url: URL, adopting page: any BrowserTab, profile: String?,
                        prepare: @escaping @MainActor () -> Bool) -> (@MainActor () -> Void)?
}

/// Opens a provider approval page in the source pane's profile and binds its
/// loopback callback to the chat's machine for the lifetime of the approval.
@MainActor
package final class ChatMachineSignInTab {
    private let localhost: RemoteLocalhostService
    private let chromiumAvailable: @MainActor () -> Bool
    private let approvalProfile: @MainActor () -> BrowserProfileID?
    private let makePage: @MainActor (BrowserTabConfiguration) async throws -> any BrowserTab
    private let requestClose: @MainActor (any BrowserTab) -> Void
    private let closeTab: @MainActor (String) -> Void

    package init(localhost: RemoteLocalhostService, chromiumAvailable: @escaping @MainActor () -> Bool,
                 approvalProfile: @escaping @MainActor () -> BrowserProfileID?,
                 makePage: @escaping @MainActor (BrowserTabConfiguration) async throws -> any BrowserTab,
                 requestClose: @escaping @MainActor (any BrowserTab) -> Void, closeTab: @escaping @MainActor (String) -> Void) {
        self.localhost = localhost
        self.chromiumAvailable = chromiumAvailable
        self.approvalProfile = approvalProfile
        self.makePage = makePage
        self.requestClose = requestClose
        self.closeTab = closeTab
    }

    /// The caller can offer manual sign-in when machine approval is unavailable.
    package func opener(for url: URL, callbackPort: @autoclosure () -> UInt16?, agentTab chat: String,
                        from host: any ChatMachineSignInHost) -> (@MainActor () -> Bool)? {
        guard let daemon = host.signInDaemon(for: chat), let port = callbackPort(), isAvailable(on: daemon) else { return nil }
        return { [weak self, weak host] in
            guard self != nil, host != nil else { return false }
            // task-owner: one page made and one tab asked for; ends once the tab is asked for.
            Task { [weak self, weak host] in
                guard let self, let host else { return }
                _ = await open(url, daemon: daemon, from: host, callbackPort: port, owner: Self.chatOwner(chat),
                               checking: host.signInLifetime(for: chat))
            }
            return true
        }
    }

    private func isAvailable(on daemon: DaemonService) -> Bool {
        guard case .machine = localhost.route(daemon: daemon, workspace: nil, engine: .cef) else { return false }
        return chromiumAvailable()
    }

    /// Opens the approval page and gives Settings a return action when requested.
    package func open(_ url: URL, daemon: DaemonService?, from host: any ChatMachineSignInHost,
                      callbackPort: UInt16, owner: String, checking current: @escaping @MainActor () -> Bool,
                      onOpened: (@MainActor (@escaping @MainActor () -> Void) -> Void)? = nil) async -> Bool {
        guard current(), daemon.map({ isAvailable(on: $0) }) ?? chromiumAvailable() else { return false }
        let profile: (wire: String?, engine: BrowserProfileID)
        if daemon != nil {
            profile = host.signInProfile()
        } else {
            guard let isolated = approvalProfile() else { return false }
            profile = (nil, isolated)
        }
        let configuration = BrowserTabConfiguration(profile: profile.engine, initialURL: url, navigationGuard: .noLoopback)
        guard let page = try? await makePage(configuration) else { return false }
        guard !Task.isCancelled, current() else { page.close(); return false }
        let prepare: @MainActor () -> Bool = { [weak self, weak page] in
            guard let self, let page, current() else { return false }
            localhost.expectCallbackPage(page, machine: daemon?.machineID, port: callbackPort, owner: owner,
                                         current: current, closePending: { [requestClose, weak page] in
                guard let page else { return }
                requestClose(page)
                page.close()
            })
            return true
        }
        guard let onOpened else {
            return host.placeSignInTab { adopt in
                guard prepare() else { page.close(); return false }
                let made = adopt(page, profile.wire)
                if !made { page.close() }
                return made
            }
        }
        guard let back = host.openSignInPage(url, adopting: page, profile: profile.wire, prepare: prepare)
        else { page.close(); return false }
        onOpened { [weak self] in
            back()
            self?.closeApproval(owner: owner)
        }
        return true
    }

    package func openSettings(_ url: URL, daemon: DaemonService?, from host: (any ChatMachineSignInHost)?,
                              callbackPort: UInt16?, owner: String, checking current: @escaping @MainActor () -> Bool,
                              onOpened: @escaping @MainActor (String, @escaping @MainActor () -> Void) -> Void) async -> Bool {
        guard let host, let callbackPort else { return false }
        return await open(url, daemon: daemon, from: host, callbackPort: callbackPort, owner: owner,
                          checking: current, onOpened: { onOpened(owner, $0) })
    }

    package func closeChatApproval(_ chat: String) { closeApproval(owner: Self.chatOwner(chat)) }

    private static func chatOwner(_ chat: String) -> String { "chat:" + chat }

    private func closeApproval(owner: String) {
        for key in localhost.endSignInApproval(owner: owner) { closeTab(key) }
    }
}
