import AppKit
import CmuxNextAgentCursor
import CmuxNextAgentCursorVisibility
import CmuxNextDaemon
import CmuxNextSettings

private typealias JSON = CmuxNextSettings.JSONValue

/// `debug.agent_cursor` (plans/cmux-next/agent-cursor.md section 3): what
/// the agent cursor visibility resolver answers right now. With `target`
/// (a browser tab id) only that tab, else every browser tab. Each entry:
/// `target`, `visibility` (`kind` visible / hidden / notDrawn with its
/// window, rects, anchor or reason), `placements` (what each window's cursor
/// host would draw, in window content-view coordinates (flipped): visible / hidden / elsewhere with rects) and
/// `snapshot_json` (the resolver input, the same shape as
/// schemas/agent-cursor-visibility/vectors.json). Read-only.
enum DebugAgentCursor {
    static func report(_ params: [String: CmuxNextSettings.JSONValue], services: AppServices) -> CmuxNextSettings.JSONValue {
        let targets = params["target"]?.stringValue.map { [$0] } ?? browserTabs(services)
        let builder = AgentCursorSnapshotBuilder(services: services)
        return .object(["targets": .array(targets.map { target in
            let snapshot = builder.snapshot(forTarget: target)
            let result = AgentCursorVisibilityResolver.resolve(target: target, in: snapshot)
            let json = (try? JSONEncoder().encode(snapshot)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return .object([
                "target": .string(target),
                "visibility": encode(result),
                "placements": .array(services.windows.controllers.map { controller -> JSON in
                    .object(["window": .string(controller.state.id),
                             "placement": encode(result.placement(forWindow: controller.state.id))])
                }),
                "snapshot_json": .string(json),
            ])
        })])
    }

    private static func browserTabs(_ services: AppServices) -> [String] {
        let daemonTabs = services.machines.allWorkspaces.flatMap { workspace, _ in
            workspace.screens.flatMap(\.panes).flatMap(\.tabs).filter { $0.kind == .browser }.map(\.id)
        }
        let localTabs = services.windows.controllers.flatMap { $0.state.localBrowserTabs.values.flatMap { $0.map(\.id) } }
        return daemonTabs + localTabs
    }

    private static func rect(_ rect: CGRect) -> JSON {
        .object(["x": .number(rect.minX), "y": .number(rect.minY), "w": .number(rect.width), "h": .number(rect.height)])
    }

    private static func encode(_ result: AgentCursorVisibility) -> JSON {
        switch result {
        case let .visible(window, viewport, clip, zoom):
            return .object(["kind": .string("visible"), "window": .string(window), "viewport": rect(viewport),
                            "clip": rect(clip), "zoom": .number(zoom)])
        case let .hidden(window, anchor, area):
            return .object(["kind": .string("hidden"), "window": .string(window), "anchor": .string(name(anchor)), "rect": rect(area)])
        case let .notDrawn(reason):
            return .object(["kind": .string("notDrawn"), "reason": .string(reason.rawValue)])
        }
    }

    private static func encode(_ placement: AgentCursorPlacement) -> JSON {
        switch placement {
        case let .visible(content, clip, zoom, magnification):
            return .object(["kind": .string("visible"), "content": rect(content), "clip": rect(clip), "zoom": .number(zoom),
                            "magnification": .number(magnification)])
        case let .hidden(anchor):
            return .object(["kind": .string("hidden"), "anchor": rect(anchor)])
        case .elsewhere:
            return .object(["kind": .string("elsewhere")])
        }
    }

    private static func name(_ anchor: AgentCursorAnchor) -> String {
        switch anchor {
        case .tabChip: "tabChip"
        case .tabStrip: "tabStrip"
        case let .columnEdge(side): "columnEdge.\(side.rawValue)"
        case .workspaceRow: "workspaceRow"
        case .windowEdge: "windowEdge"
        }
    }
}
