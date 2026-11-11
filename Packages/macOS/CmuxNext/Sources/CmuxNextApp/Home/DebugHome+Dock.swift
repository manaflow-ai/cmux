import AppKit
import CmuxHomeCore
import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextSettings

extension DebugHome {
    /// The docked Home's view (`debug.home` `dock`): which view shows, the Messages page's
    /// conversation (as it last said), the Channels page's route, and whether Channels is enabled.
    /// The Messages page's list and transcript are the page's own: ``reportWithPages(services:)`` adds them.
    /// Null while the dock tab has no view yet (or classic Home).
    static func dock(services: AppServices) -> CmuxNextSettings.JSONValue {
        guard let view = HomeDockTab.view(services) else { return .null }
        let height = view.window?.contentView?.bounds.height ?? 0
        let dockFrame = view.window.map { _ -> CGRect in
            let frame = view.convert(view.bounds, to: nil)
            return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
        }
        let box: (CGRect) -> CmuxNextSettings.JSONValue = {
            .object(["x": .number(Double($0.minX)), "y": .number(Double($0.minY)), "width": .number(Double($0.width)), "height": .number(Double($0.height))])
        }
        return .object([
            "mode": .string(view.mode.rawValue),
            "dock_frame": dockFrame.map(box) ?? .null,
            "visible": .bool(view.window != nil && !view.isHiddenOrHasHiddenAncestor),
            "messages_shown": view.messages?.shown.map { .string($0.rawValue) } ?? .null,
            "messages_visible": .bool(view.messages.map { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil } ?? false),
            "channels_route": view.channels?.route.map { .string($0) } ?? .null,
            "channels_visible": .bool(view.channels.map { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil } ?? false),
            "channels_enabled": .bool(HomeDockMode.channels.isEnabled),
            "handoff": view.lastHandoff.map { .object(["conversation": .string($0.conversation), "message": $0.message.map { .string($0) } ?? .null]) } ?? .null,
        ])
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.home.drive {action, tab?, …}`: the Messages page of Home tab `tab` (else the active
    /// window's Home) drives its list and transcript (``HomeMessagesDebug/drive(_:)``); `permalink {url}`
    /// opens a message link as the docked Home's hand-off does; `chief_name {close?}` opens the front
    /// Chief's settings with the keyboard in its name field (the chief-rename-field tour); `chief_computer` shows its Computer picker with sample machines, a capture slot having no Cloud account (the chief-computer-picker tour). The native transcript is gone.
    static func drive(_ params: [String: JSONValue], services: AppServices) async -> CmuxNextSettings.JSONValue {
        if params["action"]?.stringValue == "chief_name" {
            guard let chief = HomeChiefActions.frontHome() else { return ["error": "no Chief is shown in the front window"] }
            return .object(["ok": .bool(chief.debugEditName(close: params["close"]?.boolValue == true))])
        }
        if params["action"]?.stringValue == "chief_computer" {
            guard let chief = HomeChiefActions.frontHome() else { return ["error": "no Chief is shown in the front window"] }
            return .object(["ok": .bool(chief.debugShowComputerPicker())])
        }
        if params["action"]?.stringValue == "permalink" {
            guard let link = HomeDockSelection(link: params["url"]?.stringValue ?? "") else { return ["error": "not a link"] }
            if !services.home.dock.isClassic, let dock = HomeDockTab.view(services) { dock.open(link) } else { AppActions.listedPage(services)?.show(link) }
            return .object(["ok": .bool(true)])
        }
        return await messagesDebug(messagesPage(services, tab: params["tab"]?.stringValue))?.drive(params) ?? ["error": "no Home conversation is shown"]
    }

    /// The Messages page the DEBUG verbs drive: Home tab `tab`, else the active window's Home.
    static func messagesPage(_ services: AppServices, tab: String? = nil) -> HomeMessagesPage? {
        guard let tab else { return AppActions.listedPage(services) }
        return (services.pages.provider(.homeTab) as? HomePageTab)?.tabs.first { $0.key == tab }?.view
    }

    /// The DEBUG verbs' way into `page` (``HomeMessagesDebug``).
    static func messagesDebug(_ page: HomeMessagesPage?) -> HomeMessagesDebug? {
        page.map { page in HomeMessagesDebug(ask: { [weak page] in await page?.ask($0, $1, within: $2) }, hover: { [weak page] in await page?.page.debugHover($0) ?? .null }) }
    }

    /// `debug.home.sidebar_fixture`: the page's list fixture (``HomeMessagesDebug/sidebarFixture(_:)``).
    static func sidebarFixture(_ params: [String: JSONValue], services: AppServices) async -> CmuxNextSettings.JSONValue {
        await messagesDebug(messagesPage(services))?.sidebarFixture(params) ?? ["error": "no Home page in the active window"]
    }

    /// `debug.home` with the Messages pages' own reads: the docked page's list and transcript, each Home tab's transcript.
    static func reportWithPages(services: AppServices) async -> CmuxNextSettings.JSONValue {
        var tabs: [String: [String: CmuxNextSettings.JSONValue]] = [:]
        for tab in (services.pages.provider(.homeTab) as? HomePageTab)?.tabs ?? [] { tabs[tab.key] = await messagesDebug(tab.view)?.snapshot() }
        let docked = await messagesDebug(HomeDockTab.view(services)?.messages)?.snapshot()
        return HomeMessagesDebug.merging(report: report(services: services), dock: docked, tabs: tabs)
    }
    #endif
}
