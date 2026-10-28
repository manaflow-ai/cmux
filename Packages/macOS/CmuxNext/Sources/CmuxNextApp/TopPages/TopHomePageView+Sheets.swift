import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextWakeups
import Observation

/// Home's sheets: invite, message requests, a new Chief and a conversation's group info.
extension TopHomePageView {
    func presentInvite(prefill: String) {
        guard let services else { return }
        let home = services.home
        let pending = home.homeStore.rows.pendingInvites.map(\.contact)
        let sheet = HomeInviteSheet(prefill: prefill, pending: pending)
        sheet.onSend = { address in await home.invite(address) }
        present(sheet)
    }

    /// Message Requests: Accept opens the conversation; Decline and Block stay silent to the sender.
    func presentRequests() {
        guard let services else { return }
        let requests = services.home.requests
        let sheet = HomeRequestsSheet(requests: requests.items)
        sheet.onAnswer = { id, answer in await requests.answer(id, answer) }
        present(sheet)
        requests.refresh()
    }

    func presentNewChief() {
        guard let services else { return }
        let home = services.home
        let sheet = HomeNewChiefSheet()
        sheet.onCreate = { name, backend in await home.createChief(named: name, backend: backend) }
        present(sheet)
    }

    /// The group info sheet for `id` (a DM or group): name, members, Add People, Hide Alerts and
    /// Leave, each through `HomeService.groupActions` (Leave through its action, which asks first).
    /// It follows the conversation while it shows.
    func presentGroupInfo(_ id: ConversationID) {
        guard let services, let window else { return }
        let actions = services.home.groupActions
        guard let info = actions.info(id) else { return services.registry.refuse(HomeGroupOutcome.unknownConversation.message ?? "") }
        let registry = services.registry
        let model = HomeGroupInfoModel(info: info, addable: actions.addable(to: id), actions: HomeGroupInfoActions(
            rename: { await actions.rename(id, to: $0) },
            add: { await actions.add($0, to: id, naming: $1) },
            remove: { await actions.remove($0, from: id) },
            setMuted: { actions.setMuted($0, id) },
            leave: {
                _ = registry.perform("home.leaveConversation",
                                     invocation: ActionInvocation(arguments: ["conversation": .string(id.rawValue)], origin: .user))
            },
            inviteByEmail: { [weak self] in self?.presentInvite(prefill: "") },
            setChiefReplies: { await actions.setChiefReplies($0, id) }))
        let sheet = HomeGroupInfoSheet(model: model, colors: performWithTheme { HomeGroupInfoColors.resolve() })
        // Members, name and mute as the owner says, while the sheet shows: a view observation on this page's node (the
        // sheet hides with its window), re-read on show. The sheet's close ends it.
        let watch = VisibleObservation(visibility.node, owner: "TopHomePage.groupInfo", on: services.mainWork) {
            actions.info(id)
        } apply: { [weak sheet] info in
            guard let info else { sheet?.close(); return }
            model.update(info: info, addable: actions.addable(to: id))
        }
        sheet.onClose = { watch.cancel() }
        let panel = NSWindow(contentViewController: sheet)
        panel.isRestorable = false  // AppKit state restoration is off for every cmux window
        panel.adoptThemeScope(of: self)
        window.beginSheet(panel)
    }

    private func present(_ sheet: HomeSheetController) {
        sheet.onFinish = { [weak self] id in
            guard let self, let id else { return }
            // Opened now when listed; else once the inbox lists it.
            openWhenListed(id)
        }
        guard let window else { return }
        let panel = NSWindow(contentViewController: sheet)
        panel.isRestorable = false  // AppKit state restoration is off for every cmux window
        // The sheet draws in this page's scope (a room's own theme), not the app's: its labels
        // resolved before the sheet had a parent.
        panel.adoptThemeScope(of: self)
        window.beginSheet(panel)
    }
}
