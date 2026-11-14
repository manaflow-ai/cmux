import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextHomeEngine

/// `home.stopChief` and `home.toggleChiefSettings` from anywhere (the palette, a menu, the Chief panel's
/// Esc, `cmux action run`); a Home's own stop button, Esc and Cmd-. stop its own Chief (``stop(shown:)``).
/// The front window's Home (the one with the keyboard first) acts on the Chief it shows;
/// with none in front, Stop stops the working Chief directly and Settings brings Home forward at
/// the Chief and opens its settings (``HomeChiefActionPlan``). Each refuses with a reason only when
/// there is nothing to act on. `home.stopAllAgents` acts only on the front window's Chief Home
/// (HomeHostView+StopAll) and is unavailable, with its reason, without one.
@MainActor
enum HomeChiefActions {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("home.toggleChiefSettings", run: { _ in toggleSettings(context) })
        registry.bind(HomeChiefControl.stopAction, run: { _ in stop(context) })
        registry.bind(HomeChiefControl.stopAllAction, unavailable: { stopAllTarget() == nil ? HomeStopAllStrings.unavailable : nil },
                      run: { _ in stopAllTarget()?.stopAllAgents() })
    }

    /// The front window's Chief Home, unless a hosted cloud Chief (no stop there).
    private static func stopAllTarget() -> HomeHostView? { frontHome().flatMap { $0.chiefControl.isHosted ? nil : $0 } }

    /// The front window's Home showing a Chief, the one with the keyboard first (``HomeShownView``).
    static func frontHome() -> HomeHostView? {
        HomeShownView.find(in: HomeChiefSettingsPopover.frontToggleTarget) { ($0 as? HomeHostView).flatMap { $0.showsChiefOnScreen ? $0 : nil } }
    }

    /// A Home's own Stop (its button, Esc, Cmd-.): its Chief, never another Home's in the window.
    static func stop(shown home: HomeHostView) {
        guard home.showsChiefOnScreen, home.chiefIsWorking else { return }
        stop(home, services: home.chiefControl.services, interactive: true)
    }

    /// Stops `home`'s Chief (a hosted cloud Chief through its control), or `control`'s.
    private static func stop(_ home: HomeHostView?, control: HomeChiefControl? = nil, services: AppServices, interactive: Bool) {
        let show: (String) -> Void = { if interactive { services.refusalHUD.show($0, in: services.windows.active?.window ?? services.keyWindowSource()) } }
        guard let control = control ?? home.flatMap({ $0.chiefControl.isHosted ? $0.chiefControl : nil }) else {
            home?.turnActions.stop { show($0.text) }
            return
        }
        services.registry.track(Task {
            guard let error = await control.stop() else { return nil }
            show(error.text)
            return ActionWorkFailure(refusal: .unavailable, reason: error.text)
        })
    }

    private static func plan(_ context: AppActionContext, front: HomeHostView?) -> HomeChiefActionPlan {
        let home = context.services.home
        let defaultID = HomeChiefName.select(from: home.conversations)?.id
        let chiefs = home.homeStore.rows.filter { $0.summary.participants.contains { $0.agentClass == .chief } }.map {
            HomeChiefActionPlan.Chief(conversation: $0.summary.id, isWorking: $0.isTyping, isDefault: $0.summary.id.rawValue == defaultID)
        }
        return HomeChiefActionPlan(front: front.map { .chief(isWorking: $0.chiefIsWorking) } ?? .none, chiefs: chiefs)
    }

    private static func stop(_ context: AppActionContext) {
        let front = frontHome()
        let services = context.services
        let interactive = !context.registry.isCapturingRefusal
        switch plan(context, front: front).stop {
        case .front:
            stop(front, services: services, interactive: interactive)
        case .chief(let conversation):
            let row = services.home.homeStore.rows.first { $0.summary.id == conversation }
            stop(nil, control: HomeChiefControl(services: services, conversation: conversation,
                                                muxHome: HomeBrainHost.muxHome(tag: services.environment.tag),
                                                chief: row.flatMap { ChiefHome.namedChief(in: $0.summary.participants) }),
                 services: services, interactive: interactive)
        case .nothingRuns:
            // Esc or Cmd-. with nothing running shows nothing; a caller (palette, CLI) gets the reason.
            context.refuseQuietly(MiscHandlerStrings.noWorkingChief)
        }
    }

    private static func toggleSettings(_ context: AppActionContext) {
        let front = frontHome()
        switch plan(context, front: front).settings {
        case .front:
            front?.toggleChiefSettings()
        case .open(let conversation):
            let services = context.services
            services.home.pendingChiefSettings = conversation
            // Its Home view opens the settings once it shows the Chief (HomeHostView.openPendingSettings).
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
