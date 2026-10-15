import AppKit
import CmuxNextHome
import CmuxNextSettings

extension DebugHome {
    /// The docked Home's view (`debug.home` `dock`): which view shows, the Messages view's
    /// conversation and open thread, the Channels page's route, and the header switch's state.
    /// Null while the dock tab has no view yet (or classic Home).
    static func dock(services: AppServices) -> CmuxNextSettings.JSONValue {
        guard let view = HomeDockTab.view(services) else { return .null }
        let transcript = view.messages?.host.flatMap { HomePageTab.transcript(in: $0) }
        let control = view.control
        // The switch in window points from the top-left (debug.mouse's `x`,`y`), for a click.
        let height = view.window?.contentView?.bounds.height ?? 0
        let header = view.header.window.map { _ -> CGRect in
            let frame = view.header.convert(control.frame, to: nil)
            return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
        }
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
            "switch_selected": .number(Double(control.selectedSegment)),
            "switch_labels": .array((0..<control.segmentCount).map { .string(control.label(forSegment: $0) ?? "") }),
            "switch_frame": header.map(box) ?? .null,
            "handoff": view.lastHandoff.map { .object(["conversation": .string($0.conversation), "message": $0.message.map { .string($0) } ?? .null]) } ?? .null,
        ])
    }
}
