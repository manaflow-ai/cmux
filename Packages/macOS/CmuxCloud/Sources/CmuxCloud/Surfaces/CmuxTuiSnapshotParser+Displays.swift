import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSnapshotParser {
    /// The machine's display list after a snapshot: a display the daemon's workspaces point
    /// at (carrying its views) replaces the bare pool entry of the same id; every other
    /// resource passes through. Pure, so the provider's refresh stays a straight line.
    public static func mergingDisplays(pool: [SurfaceResource], parsed: [SurfaceResource]) -> [SurfaceResource] {
        let pointed = Set(parsed.filter { $0.kind == .display }.map(\.id))
        let targets = Dictionary(pool.filter { $0.kind == .display }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return pool.filter { !($0.kind == .display && pointed.contains($0.id)) } + parsed.map { resource in
            guard var target = targets[resource.id] else { return resource }
            target.remoteViews = resource.remoteViews
            target.remoteWorkspace = resource.remoteWorkspace
            return target
        }
    }

}
