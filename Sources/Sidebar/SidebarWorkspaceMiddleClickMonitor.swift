import AppKit

/// Window-scoped middle-click routing for the workspace sidebar.
@MainActor
final class SidebarWorkspaceMiddleClickMonitor {
    private var localMonitor: Any?
    private var hoverGeneration: UInt = 0
    private(set) var hoveredWorkspaceId: UUID?

    func setHoveredWorkspace(_ workspaceId: UUID, hovering: Bool) {
        hoverGeneration &+= 1
        if hovering {
            hoveredWorkspaceId = workspaceId
        } else if hoveredWorkspaceId == workspaceId {
            hoveredWorkspaceId = nil
        }
    }

    /// A lazy row can disappear while the pointer is stationary. Clear its
    /// target after the current SwiftUI transaction, unless a newer hover event
    /// has already selected the same remounted row or a different row.
    func invalidateHoveredWorkspace(_ workspaceId: UUID) {
        let invalidationGeneration = hoverGeneration
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  hoverGeneration == invalidationGeneration,
                  hoveredWorkspaceId == workspaceId else { return }
            hoveredWorkspaceId = nil
        }
    }

    func start(
        window: NSWindow?,
        onMiddleClick: @escaping @MainActor () -> Bool
    ) {
        stop()
        guard let window else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak window] event in
            guard event.buttonNumber == 2, event.window === window else { return event }
            // AppKit invokes local event monitors on the main thread.
            let handled = MainActor.assumeIsolated {
                onMiddleClick()
            }
            return handled ? nil : event
        }
    }

    func stop() {
        hoverGeneration &+= 1
        hoveredWorkspaceId = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        self.localMonitor = nil
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }
}
