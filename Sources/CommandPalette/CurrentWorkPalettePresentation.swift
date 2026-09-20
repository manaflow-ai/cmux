import Foundation

/// Pure presentation of the same bounded values returned by `current.list`.
/// Navigation still resolves through SurfaceCatalog and the current window owners.
enum CurrentWorkPalettePresentation {
    static func matches(
        item: CurrentWorkSnapshot.Item,
        projection: CurrentWorkSnapshot.Projection,
        current: SurfaceProjection
    ) -> Bool {
        projection.resourceRef == item.resourceRef
            && current.resource.rawValue == item.resourceRef
            && current.panelID == projection.panelID
    }

    static func subtitle(item: CurrentWorkSnapshot.Item, canFocus: Bool) -> String {
        var parts: [String] = []
        if let cwd = item.cwd, !cwd.isEmpty { parts.append(cwd) }
        if item.placement.kind == "cloud" { parts.append(item.placement.machine) }
        if !item.agents.isEmpty {
            parts.append(String(localized: "commandPalette.kind.agentSession", defaultValue: "Agent"))
        }
        if !item.attention.isEmpty {
            parts.append(String(localized: "commandPalette.currentWork.attention", defaultValue: "Attention"))
        }
        parts.append(contentsOf: item.pullRequests.map { "PR #\($0.number)" })
        if item.freshness.state != "current" {
            parts.append(String(localized: "commandPalette.currentWork.notCurrent", defaultValue: "May be out of date"))
        }
        if !canFocus {
            parts.append(String(localized: "commandPalette.currentWork.notOpen", defaultValue: "No open local view · read only"))
        }
        return parts.joined(separator: " • ")
    }
}
