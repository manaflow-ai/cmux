import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextHomeEngine

/// `home.stopChief` and `home.toggleChiefSettings` from anywhere (the palette, a menu, the compose
/// bar's Stop, Esc and Cmd-., `cmux action run`). The front window's Home acts on the Chief it shows;
/// with none in front, Stop stops the working Chief directly and Settings brings Home forward at
/// the Chief and opens its settings (``HomeChiefActionPlan``). Each refuses with a reason only when
/// there is nothing to act on. `home.stopAllAgents` acts only on the front window's Chief Home
/// (``HomeChiefSurface/stopAllAgents()``) and is unavailable, with its reason, without one.
@MainActor
enum HomeChiefActions {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("home.toggleChiefSettings", run: { _ in toggleSettings(context) })
        registry.bind(HomeChiefControl.stopAction, run: { _ in stop(context) })
        registry.bind(HomeChiefControl.stopAllAction, unavailable: { stopAllTarget() == nil ? HomeStopAllStrings.unavailable : nil },
                      run: { _ in stopAllTarget()?.stopAllAgents() })
    }

    /// The front window's Chief Home, unless a hosted cloud Chief (no stop there).
    private static func stopAllTarget() -> HomeChiefSurface? {
        frontHome().flatMap { $0.control.isHosted ? nil : $0 }
    }

    /// The Chief a Messages page in the front window (``HomeChiefSettingsPopover/frontToggleTarget``) shows:
    /// the docked page, a conversation tab or the Chief panel, the one with the keyboard first (``HomeShownView``).
    static func frontHome() -> HomeChiefSurface? {
        HomeShownView.find(in: HomeChiefSettingsPopover.frontToggleTarget) { ($0 as? any HomeChiefShowing)?.shownChief }
    }

    private static func plan(_ context: AppActionContext, front: HomeChiefSurface?) -> HomeChiefActionPlan {
        let home = context.services.home
        let defaultID = HomeChiefName.select(from: home.conversations)?.id
        let chiefs = home.homeStore.rows.filter { $0.summary.participants.contains { $0.agentClass == .chief } }.map {
            HomeChiefActionPlan.Chief(conversation: $0.summary.id, isWorking: $0.isTyping, isDefault: $0.summary.id.rawValue == defaultID)
        }
        return HomeChiefActionPlan(front: front.map { .chief(isWorking: $0.isWorking) } ?? .none, chiefs: chiefs)
    }

    private static func stop(_ context: AppActionContext) {
        let front = frontHome()
        let control: HomeChiefControl
        switch plan(context, front: front).stop {
        case .front:
            guard let front else { return }
            if front.control.isHosted {
                control = front.control
                break
            }
            let interactive = !context.registry.isCapturingRefusal
            let services = context.services
            front.turnActions.stop { error in
                if interactive { services.refusalHUD.show(error.text, in: services.windows.active?.window ?? services.keyWindowSource()) }
            }
            return
        case .chief(let conversation):
            let row = context.services.home.homeStore.rows.first { $0.summary.id == conversation }
            control = HomeChiefControl(services: context.services, conversation: conversation,
                                       muxHome: HomeBrainHost.muxHome(tag: context.services.environment.tag),
                                       chief: row.flatMap { ChiefHome.namedChief(in: $0.summary.participants) })
        case .nothingRuns:
            // Esc or Cmd-. with nothing running shows nothing; a caller (palette, CLI) gets the reason.
            return context.refuseQuietly(MiscHandlerStrings.noWorkingChief)
        }
        let registry = context.registry
        let interactive = !registry.isCapturingRefusal
        let services = context.services
        let work: ActionWork = Task {
            guard let error = await control.stop() else { return nil }
            if interactive { services.refusalHUD.show(error.text, in: services.windows.active?.window ?? services.keyWindowSource()) }
            return ActionWorkFailure(refusal: .unavailable, reason: error.text)
        }
        registry.track(work)
    }

    private static func toggleSettings(_ context: AppActionContext) {
        let front = frontHome()
        switch plan(context, front: front).settings {
        case .front:
            front?.toggleSettings()
        case .open(let conversation):
            let services = context.services
            services.home.pendingChiefSettings = conversation
            // Its Home view opens the settings once it shows the Chief (HomeChiefSurface.openPendingSettings).
            if services.home.dock.isClassic {
                AppActions.homePage(services)?.open(conversation)
            } else {
                AppActions.withDock(services) { dock in
                    dock.switchTo(.messages, selection: HomeDockSelection(conversation: conversation.rawValue))
                }
            }
        case .noChief:
            context.refuse(MiscHandlerStrings.noChief)
        }
    }
}
