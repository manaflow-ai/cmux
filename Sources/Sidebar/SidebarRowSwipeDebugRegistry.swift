import AppKit

#if DEBUG
@MainActor
final class SidebarRowSwipeDebugRegistry {
    enum Action: Equatable {
        case revealLeading
        case revealTrailing
        case commitLeading
        case commitTrailing
        case release
    }

    struct Result: Equatable {
        let committed: Bool
        let offset: CGFloat
        let released: Bool
    }

    private final class Entry {
        weak var view: SidebarRowSwipeCaptureNSView?

        init(view: SidebarRowSwipeCaptureNSView) {
            self.view = view
        }
    }

    private var entriesByWorkspaceId: [UUID: Entry] = [:]

    func register(workspaceId: UUID, view: SidebarRowSwipeCaptureNSView) {
        entriesByWorkspaceId[workspaceId] = Entry(view: view)
    }

    func unregister(workspaceId: UUID, view: SidebarRowSwipeCaptureNSView) {
        guard entriesByWorkspaceId[workspaceId]?.view === view else { return }
        entriesByWorkspaceId.removeValue(forKey: workspaceId)
    }

    func simulateSwipe(workspaceId: UUID, action: Action) -> Result? {
        guard let entry = entriesByWorkspaceId[workspaceId],
              let view = entry.view else {
            entriesByWorkspaceId.removeValue(forKey: workspaceId)
            return nil
        }
        return view.debugSimulateSwipe(action)
    }
}
#endif
