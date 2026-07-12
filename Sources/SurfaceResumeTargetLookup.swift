import Foundation

struct SurfaceResumeTargetLocation {
    let workspaceId: UUID
    let surfaceId: UUID
    let tabManager: TabManager
}

enum SurfaceResumeTargetLookup {
    case found(SurfaceResumeTargetLocation)
    case missing
    case ambiguous
}

extension TabManager {
    /// Resolves a resume target only when exactly one workspace and terminal match.
    func locateSurfaceResumeTarget(surfaceId targetId: UUID) -> SurfaceResumeTargetLookup {
        var match: SurfaceResumeTargetLocation?
        for workspace in tabs {
            switch workspace.surfaceResumeTargetLookup(targetId) {
            case .found(let surfaceId):
                guard match == nil else { return .ambiguous }
                match = SurfaceResumeTargetLocation(
                    workspaceId: workspace.id,
                    surfaceId: surfaceId,
                    tabManager: self
                )
            case .ambiguous:
                return .ambiguous
            case .missing:
                continue
            }
        }
        guard let match else { return .missing }
        return .found(match)
    }
}

extension AppDelegate {
    /// Locates a terminal globally only when its runtime or restart-stable id is unique.
    func locateSurfaceResumeTarget(
        surfaceId targetId: UUID,
        including fallbackTabManager: TabManager? = nil
    ) -> SurfaceResumeTargetLookup {
        var match: SurfaceResumeTargetLocation?
        var isAmbiguous = false
        var visitedManagers = Set<ObjectIdentifier>()

        func inspect(tabManager: TabManager) {
            guard !isAmbiguous,
                  visitedManagers.insert(ObjectIdentifier(tabManager)).inserted else {
                return
            }
            switch tabManager.locateSurfaceResumeTarget(surfaceId: targetId) {
            case .found(let located):
                guard match == nil else {
                    isAmbiguous = true
                    return
                }
                match = located
            case .ambiguous:
                isAmbiguous = true
            case .missing:
                break
            }
        }

        for context in mainWindowContexts.values {
            inspect(tabManager: context.tabManager)
        }
        for route in recoverableMainWindowRoutes() {
            guard let tabManager = route.tabManager else { continue }
            inspect(tabManager: tabManager)
        }
        if let fallbackTabManager {
            inspect(tabManager: fallbackTabManager)
        }

        if isAmbiguous { return .ambiguous }
        guard let match else { return .missing }
        return .found(match)
    }
}
