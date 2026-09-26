import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// Pure presentation of the same bounded values returned by `current.list`.
/// Navigation still resolves through SurfaceCatalog and the current window owners.
struct CurrentWorkPalettePresentation {
    let item: CurrentWorkSnapshot.Item

    func matches(
        projection: CurrentWorkSnapshot.Projection,
        current: SurfaceProjection
    ) -> Bool {
        projection.resourceRef == item.resourceRef
            && current.resource.rawValue == item.resourceRef
            && current.panelID == projection.panelID
    }

    func subtitle(canFocus: Bool) -> String {
        var parts: [String] = []
        if let cwd = item.cwd, !cwd.isEmpty { parts.append(cwd) }
        if item.placement.kind == "cloud" { parts.append(item.placement.machine) }
        if !item.agents.isEmpty {
            parts.append(String(localized: "commandPalette.kind.agentSession", defaultValue: "Agent"))
        }
        if !item.attention.isEmpty {
            parts.append(String(localized: "commandPalette.currentWork.attention", defaultValue: "Attention"))
        }
        let pullRequestFormat = String(localized: "cli.current.pullRequest", defaultValue: "PR: %@")
        if let placeholder = pullRequestFormat.range(of: "%@") {
            let prefix = String(pullRequestFormat[..<placeholder.lowerBound])
            let suffix = String(pullRequestFormat[placeholder.upperBound...])
            for pullRequest in item.pullRequests {
                let identifier = "#\(pullRequest.number)"
                var label = String()
                label.reserveCapacity(prefix.count + identifier.count + suffix.count)
                label.append(contentsOf: prefix)
                label.append(contentsOf: identifier)
                label.append(contentsOf: suffix)
                parts.append(label)
            }
        } else {
            parts.append(contentsOf: item.pullRequests.map { _ in pullRequestFormat })
        }
        if item.freshness.state != "current" {
            parts.append(String(localized: "commandPalette.currentWork.notCurrent", defaultValue: "May be out of date"))
        }
        if !canFocus {
            parts.append(String(localized: "commandPalette.currentWork.notOpen", defaultValue: "No open local view · read only"))
        }
        return parts.joined(separator: " • ")
    }
}
