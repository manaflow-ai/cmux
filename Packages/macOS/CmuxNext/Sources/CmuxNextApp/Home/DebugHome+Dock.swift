import AppKit
import CmuxHomeCore
import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextSettings

extension DebugHome {
    /// The docked Home's view (`debug.home` `dock`): which view shows, the Messages page's
    /// conversation (as it last said), the Channels page's route, and whether Channels is enabled.
    /// The Messages page's list and transcript are the page's own: read them from the page.
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
}
