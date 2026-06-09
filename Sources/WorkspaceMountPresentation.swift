import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

enum WorkspaceMountPolicy {
    // Keep only the selected workspace mounted to minimize layer-tree traversal.
    static let maxMountedWorkspaces = 1
    // During workspace cycling, keep only a minimal handoff pair (selected + retiring).
    static let maxMountedWorkspacesDuringCycle = 2

    static func nextMountedWorkspaceIds(
        current: [UUID],
        selected: UUID?,
        pinnedIds: Set<UUID>,
        orderedTabIds: [UUID],
        isCycleHot: Bool,
        maxMounted: Int
    ) -> [UUID] {
        let existing = Set(orderedTabIds)
        let clampedMax = max(1, maxMounted)
        var ordered = current.filter { existing.contains($0) }

        if let selected, existing.contains(selected) {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }

        if isCycleHot, let selected {
            let warmIds = cycleWarmIds(selected: selected, orderedTabIds: orderedTabIds)
            for id in warmIds.reversed() {
                ordered.removeAll { $0 == id }
                ordered.insert(id, at: 0)
            }
        }

        if isCycleHot,
           pinnedIds.isEmpty,
           let selected {
            ordered.removeAll { $0 != selected }
        }

        // Ensure pinned ids (retiring handoff workspaces) are always retained at highest priority.
        // This runs after warming to prevent neighbor warming from evicting the retiring workspace.
        let prioritizedPinnedIds = pinnedIds
            .filter { existing.contains($0) && $0 != selected }
            .sorted { lhs, rhs in
                let lhsIndex = orderedTabIds.firstIndex(of: lhs) ?? .max
                let rhsIndex = orderedTabIds.firstIndex(of: rhs) ?? .max
                return lhsIndex < rhsIndex
            }
        if let selected, existing.contains(selected) {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }
        var pinnedInsertionIndex = (selected != nil) ? 1 : 0
        for pinnedId in prioritizedPinnedIds {
            ordered.removeAll { $0 == pinnedId }
            let insertionIndex = min(pinnedInsertionIndex, ordered.count)
            ordered.insert(pinnedId, at: insertionIndex)
            pinnedInsertionIndex += 1
        }

        if ordered.count > clampedMax {
            ordered.removeSubrange(clampedMax...)
        }

        return ordered
    }

    private static func cycleWarmIds(selected: UUID, orderedTabIds: [UUID]) -> [UUID] {
        guard orderedTabIds.contains(selected) else { return [selected] }
        // Keep warming focused to the selected workspace. Retiring/target workspaces are
        // pinned by handoff logic, so warming adjacent neighbors here just adds layout work.
        return [selected]
    }
}

struct MountedWorkspacePresentation: Equatable {
    let isRenderedVisible: Bool
    let isPanelVisible: Bool
    let renderOpacity: Double
}

enum MountedWorkspacePresentationPolicy {
    static func resolve(
        isSelectedWorkspace: Bool,
        isRetiringWorkspace: Bool
    ) -> MountedWorkspacePresentation {
        let isRenderedVisible = isSelectedWorkspace || isRetiringWorkspace

        return MountedWorkspacePresentation(
            isRenderedVisible: isRenderedVisible,
            isPanelVisible: isRenderedVisible,
            renderOpacity: isRenderedVisible ? 1 : 0
        )
    }
}

/// Installs a FileDropOverlayView on the window's theme frame for Finder file drag support.
private func findFileDropOverlayView(in root: NSView?) -> FileDropOverlayView? {
    guard let root else { return nil }
    if let overlay = root as? FileDropOverlayView {
        return overlay
    }
    for subview in root.subviews {
        if let overlay = findFileDropOverlayView(in: subview) {
            return overlay
        }
    }
    return nil
}

private func configureFileDropOverlay(_ overlay: FileDropOverlayView, tabManager: TabManager) {
    overlay.onDrop = { [weak tabManager] urls in
        MainActor.assumeIsolated {
            guard let tabManager, let terminal = tabManager.selectedWorkspace?.focusedTerminalPanel else { return false }
            return terminal.hostedView.handleDroppedURLs(urls)
        }
    }
}

private func attachFileDropOverlay(
    _ overlay: FileDropOverlayView,
    to referenceView: NSView,
    in containerView: NSView
) {
    overlay.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(overlay, positioned: .above, relativeTo: referenceView)
    NSLayoutConstraint.activate([
        overlay.topAnchor.constraint(equalTo: referenceView.topAnchor),
        overlay.bottomAnchor.constraint(equalTo: referenceView.bottomAnchor),
        overlay.leadingAnchor.constraint(equalTo: referenceView.leadingAnchor),
        overlay.trailingAnchor.constraint(equalTo: referenceView.trailingAnchor)
    ])
}

private func fileDropOverlay(
    _ overlay: FileDropOverlayView,
    isAttachedTo referenceView: NSView,
    in containerView: NSView
) -> Bool {
    guard overlay.superview === containerView else { return false }
    let requiredAttributes: [NSLayoutConstraint.Attribute] = [.top, .bottom, .leading, .trailing]
    return requiredAttributes.allSatisfy { attribute in
        containerView.constraints.contains { constraint in
            let firstView = constraint.firstItem as? NSView
            let secondView = constraint.secondItem as? NSView
            return firstView === overlay &&
                secondView === referenceView &&
                constraint.firstAttribute == attribute &&
                constraint.secondAttribute == attribute
        }
    }
}

@discardableResult
func installFileDropOverlay(on window: NSWindow, tabManager: TabManager) -> Bool {
    guard let target = windowContentOverlayInstallationTarget(for: window) else { return false }

    let existingOverlay =
        (objc_getAssociatedObject(window, &fileDropOverlayKey) as? FileDropOverlayView)
        ?? findFileDropOverlayView(in: target.container)

    if let existingOverlay {
        configureFileDropOverlay(existingOverlay, tabManager: tabManager)
        objc_setAssociatedObject(window, &fileDropOverlayKey, existingOverlay, .OBJC_ASSOCIATION_RETAIN)
        guard !fileDropOverlay(existingOverlay, isAttachedTo: target.reference, in: target.container) else {
            return true
        }
        existingOverlay.removeFromSuperview()
        attachFileDropOverlay(existingOverlay, to: target.reference, in: target.container)
        return true
    }

    let overlay = FileDropOverlayView(frame: target.reference.frame)
    configureFileDropOverlay(overlay, tabManager: tabManager)
    // Publish the overlay before mutating the view tree so any re-entrant lookup resolves
    // the in-flight view instead of installing a second overlay during layout.
    objc_setAssociatedObject(window, &fileDropOverlayKey, overlay, .OBJC_ASSOCIATION_RETAIN)
    attachFileDropOverlay(overlay, to: target.reference, in: target.container)
    return true
}

func installFileDropOverlayWhenReady(
    on window: NSWindow,
    tabManager: TabManager,
    remainingAttempts: Int = 16
) {
    guard !installFileDropOverlay(on: window, tabManager: tabManager),
          remainingAttempts > 0 else { return }

    // Defer retrying until the next main-loop turn so we don't mutate the
    // NSThemeFrame hierarchy while SwiftUI/AppKit is still attaching views.
    DispatchQueue.main.async { [weak window, weak tabManager] in
        guard let window, let tabManager else { return }
        installFileDropOverlayWhenReady(
            on: window,
            tabManager: tabManager,
            remainingAttempts: remainingAttempts - 1
        )
    }
}

@MainActor
final class SelectedWorkspaceDirectoryObserver: ObservableObject {
    private struct Snapshot: Equatable {
        let workspaceId: UUID?
        let currentDirectory: String?
        let remoteConfiguration: WorkspaceRemoteConfiguration?
        let remoteConnectionState: WorkspaceRemoteConnectionState?
        let remoteConnectionDetail: String?
        let remoteDaemonStatus: WorkspaceRemoteDaemonStatus?
    }

    @Published private(set) var directoryChangeGeneration: UInt64 = 0
    private weak var tabManager: TabManager?
    private var cancellable: AnyCancellable?

    func wire(tabManager: TabManager) {
        guard self.tabManager !== tabManager || cancellable == nil else { return }
        self.tabManager = tabManager
        cancellable = tabManager.$selectedTabId
            .map { [weak tabManager] tabId -> Workspace? in
                guard let tabId, let tabManager else { return nil }
                return tabManager.tabs.first(where: { $0.id == tabId })
            }
            .removeDuplicates(by: { $0?.id == $1?.id })
            .map { workspace -> AnyPublisher<Snapshot, Never> in
                guard let workspace else {
                    return Just(
                        Snapshot(
                            workspaceId: nil,
                            currentDirectory: nil,
                            remoteConfiguration: nil,
                            remoteConnectionState: nil,
                            remoteConnectionDetail: nil,
                            remoteDaemonStatus: nil
                        )
                    )
                    .eraseToAnyPublisher()
                }
                return workspace.$currentDirectory
                    .combineLatest(
                        workspace.$remoteConfiguration,
                        workspace.$remoteConnectionState,
                        workspace.$remoteConnectionDetail
                    )
                    .combineLatest(workspace.$remoteDaemonStatus)
                    .map { values, remoteDaemonStatus in
                        let (
                            currentDirectory,
                            remoteConfiguration,
                            remoteConnectionState,
                            remoteConnectionDetail
                        ) = values
                        return Snapshot(
                            workspaceId: workspace.id,
                            currentDirectory: currentDirectory,
                            remoteConfiguration: remoteConfiguration,
                            remoteConnectionState: remoteConnectionState,
                            remoteConnectionDetail: remoteConnectionDetail,
                            remoteDaemonStatus: remoteDaemonStatus
                        )
                    }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.directoryChangeGeneration &+= 1
            }
    }
}

func titlebarShortcutHintShouldShow(
    shortcut: StoredShortcut,
    alwaysShowShortcutHints: Bool,
    modifierPressed: Bool
) -> Bool {
    !shortcut.isUnbound && (alwaysShowShortcutHints || (shortcut.command && modifierPressed))
}
