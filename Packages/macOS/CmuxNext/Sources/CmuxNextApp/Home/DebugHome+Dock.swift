import AppKit
import CmuxHomeCore
import CmuxNextHome
import CmuxNextSettings

extension DebugHome {
    /// The docked Home's view (`debug.home` `dock`): which view shows, the Messages view's
    /// conversation and open thread, the Channels page's route, and whether Channels is enabled.
    /// Null while the dock tab has no view yet (or classic Home).
    static func dock(services: AppServices) -> CmuxNextSettings.JSONValue {
        guard let view = HomeDockTab.view(services) else { return .null }
        let transcript = view.messages?.host.flatMap { HomePageTab.transcript(in: $0) }
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
            "open_thread": transcript?.openThreadRoot.map { .string($0) } ?? .null,
            "transcript_tail": .array((transcript?.debugMessageTexts() ?? []).map { .string($0) }),
            "channels_route": view.channels?.route.map { .string($0) } ?? .null,
            "channels_visible": .bool(view.channels.map { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil } ?? false),
            "channels_enabled": .bool(HomeDockMode.channels.isEnabled),
            // The Messages list as drawn: the pinned grid, then the rows (id, title, pinned, unread).
            "messages_list": .array(((view.messages?.list.model).map { $0.pinned + $0.rows } ?? []).map { item in
                .object(["id": .string(item.id.rawValue), "title": .string(item.title), "pinned": .bool(item.isPinned),
                         "unread": .bool(item.unread), "chief": .bool(item.isChief)])
            }),
            "messages_note": view.messages?.list.model.note.map { .string($0) } ?? .null, "messages_cloud": view.messages?.list.model.cloudState.map { .string($0) } ?? .null,
            "handoff": view.lastHandoff.map { .object(["conversation": .string($0.conversation), "message": $0.message.map { .string($0) } ?? .null]) } ?? .null,
        ])
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.home.drive {action: legacy_pins, pins?}`: the Messages-list pins this Mac keeps (the old
    /// store the one-time move reads, HomePinMigration), after setting them to `pins` when given.
    static func legacyPins(_ params: [String: JSONValue], services: AppServices) -> CmuxNextSettings.JSONValue {
        let pins = params["pins"]?.arrayValue.map { $0.compactMap(\.stringValue) }
        return .object(["ok": .bool(true), "pins": .array(services.home.pinMigration.debugPins(pins).map { .string($0) })])
    }
    #endif

    /// `debug.home.drive {action: list, op: pin | unpin | unread | read, conversation}`: the docked Messages list's menu handlers.
    static func driveDockList(_ params: [String: JSONValue], services: AppServices) -> CmuxNextSettings.JSONValue {
        let fail = { (why: String) in CmuxNextSettings.JSONValue.object(["ok": .bool(false), "error": .string(why)]) }
        guard let list = HomeDockTab.view(services)?.messages?.list, let id = params["conversation"]?.stringValue else { return fail("no docked Messages list, or no conversation") }
        let ops: [String: (ConversationID) -> Void] = ["pin": { list.onSetPinned(true, $0) }, "unpin": { list.onSetPinned(false, $0) },
                                                       "unread": list.onMarkUnread, "read": list.onMarkRead]
        guard let op = params["op"]?.stringValue.flatMap({ ops[$0] }) else { return fail("op must be pin, unpin, unread or read") }
        op(ConversationID(id))
        return .object(["ok": .bool(true)])
    }
}
