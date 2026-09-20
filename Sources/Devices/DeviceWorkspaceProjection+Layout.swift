import CMUXMobileCore
import CmuxCore
import Foundation

extension DeviceWorkspaceProjection {
    /// One surface's exact position and selection within the source pane tree.
    struct LayoutLocation {
        let paneID: String
        let paneIndex: Int
        let tabIndex: Int
        let isSelected: Bool
    }

    func layoutLocations(_ layout: DeviceWorkspaceLayoutNode?) -> [String: LayoutLocation] {
        guard let layout else { return [:] }
        var locations: [String: LayoutLocation] = [:]
        var paneIndex = 0
        index(layout, paneIndex: &paneIndex, locations: &locations)
        return locations
    }

    private func index(_ node: DeviceWorkspaceLayoutNode, paneIndex: inout Int, locations: inout [String: LayoutLocation]) {
        switch node {
        case .pane(let id, let surfaces, let selected):
            for (tabIndex, surface) in surfaces.enumerated() {
                locations[surface] = LayoutLocation(
                    paneID: id, paneIndex: paneIndex, tabIndex: tabIndex,
                    isSelected: surface == (selected ?? surfaces.first)
                )
            }
            paneIndex += 1
        case .split(_, _, let first, let second):
            index(first, paneIndex: &paneIndex, locations: &locations)
            index(second, paneIndex: &paneIndex, locations: &locations)
        }
    }

    /// Uses the same resources as the sidebar, preserving native splits and tab order.
    func projectionLayout(_ record: WorkspaceSyncRecord, layout: DeviceWorkspaceLayoutNode) -> SurfaceProjectionLayout? {
        let placements = Dictionary(resources([record], layouts: [record.id: layout]).map { resource in
            (resource.id.key, SurfaceResourcePlacement(resource: resource.id, remoteView: resource.remoteViews?.first))
        }, uniquingKeysWith: { first, _ in first })
        return translate(layout, placements: placements)
    }

    private func translate(_ node: DeviceWorkspaceLayoutNode, placements: [String: SurfaceResourcePlacement]) -> SurfaceProjectionLayout? {
        switch node {
        case .pane(_, let surfaces, _):
            let members = surfaces.compactMap { placements[$0] }
            return members.isEmpty ? nil : .leaf(placements: members)
        case .split(let direction, let ratio, let first, let second):
            let first = translate(first, placements: placements)
            let second = translate(second, placements: placements)
            switch (first, second) {
            case (let first?, let second?):
                return .split(
                    direction: direction == .horizontal ? .right : .down,
                    ratio: CloudWorkspaceLayoutTranslator.clampedRatio(ratio),
                    first: first, second: second
                )
            case (let first?, nil): return first
            case (nil, let second?): return second
            case (nil, nil): return nil
            }
        }
    }
}
