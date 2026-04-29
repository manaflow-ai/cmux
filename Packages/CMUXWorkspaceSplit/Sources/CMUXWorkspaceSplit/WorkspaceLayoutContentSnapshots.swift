import AppKit
import Foundation
import SwiftUI


@MainActor
enum WorkspacePaneContent {
    case terminal(WorkspaceTerminalPaneContent)
    case browser(WorkspaceBrowserPaneContent)
    case markdown(WorkspaceMarkdownPaneContent)
    case placeholder(WorkspacePlaceholderPaneContent)
}

enum WorkspacePaneMountIdentity: Hashable {
    case terminal(UUID)
    case browser(UUID)
    case markdown(UUID)
    case placeholder(UUID)
}

extension WorkspacePaneContent {
    var usesDirectPaneHost: Bool {
        switch self {
        case .terminal, .browser:
            return true
        case .markdown, .placeholder:
            return false
        }
    }

    func mountIdentity(contentId: UUID) -> WorkspacePaneMountIdentity {
        switch self {
        case .terminal(let descriptor):
            return .terminal(descriptor.surfaceId)
        case .browser(let descriptor):
            return .browser(descriptor.surfaceId)
        case .markdown(let descriptor):
            return .markdown(descriptor.surfaceId)
        case .placeholder:
            return .placeholder(contentId)
        }
    }
}

enum WorkspaceSurfaceRevealPhase: Equatable, Sendable {
    case hidden
    case waitingForWindow
    case waitingForGeometry
    case waitingForRuntime
    case waitingForFirstFrame
    case visible

    init(lifecycleFacts: WorkspaceSurfaceLifecycleFacts) {
        if !lifecycleFacts.isVisibleInUI {
            self = .hidden
        } else if !lifecycleFacts.isWindowed {
            self = .waitingForWindow
        } else if !lifecycleFacts.hasUsableGeometry {
            self = .waitingForGeometry
        } else if !lifecycleFacts.hasRuntime {
            self = .waitingForRuntime
        } else if !lifecycleFacts.hasPresentedFrame {
            self = .waitingForFirstFrame
        } else {
            self = .visible
        }
    }

    var showsLoadingCover: Bool {
        switch self {
        case .hidden, .visible:
            false
        case .waitingForWindow, .waitingForGeometry, .waitingForRuntime, .waitingForFirstFrame:
            true
        }
    }
}

struct WorkspaceSurfaceLifecycleFacts: Equatable, Sendable {
    let isVisibleInUI: Bool
    let isWindowed: Bool
    let hasUsableGeometry: Bool
    let hasRuntime: Bool
    let hasPresentedFrame: Bool
}

struct WorkspaceSurfacePresentationFacts: Equatable, Sendable {
    let revealPhase: WorkspaceSurfaceRevealPhase

    var isVisible: Bool {
        revealPhase == .visible
    }

    var showsLoadingCover: Bool {
        revealPhase.showsLoadingCover
    }

    static let hidden = WorkspaceSurfacePresentationFacts(revealPhase: .hidden)
    static let visible = WorkspaceSurfacePresentationFacts(revealPhase: .visible)

    static func terminal(_ facts: WorkspaceSurfaceLifecycleFacts) -> WorkspaceSurfacePresentationFacts {
        WorkspaceSurfacePresentationFacts(revealPhase: WorkspaceSurfaceRevealPhase(lifecycleFacts: facts))
    }
}

@MainActor
struct WorkspaceTerminalPaneAppearance {
    let unfocusedOverlayNSColor: NSColor
    let unfocusedOverlayOpacity: Double
}

@MainActor
struct WorkspaceTerminalPaneContent {
    let surfaceId: UUID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let isSplit: Bool
    let appearance: WorkspaceTerminalPaneAppearance
    let hasUnreadNotification: Bool
    let onFocus: () -> Void
    let onTriggerFlash: () -> Void
}

@MainActor
struct WorkspaceBrowserPaneContent {
    let surfaceId: UUID
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let prefersLocalInlineHosting: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void
}

@MainActor
struct WorkspaceMarkdownPaneContent {
    let surfaceId: UUID
    let isVisibleInUI: Bool
    let onRequestPanelFocus: () -> Void
}

@MainActor
struct WorkspacePlaceholderPaneContent {
    let paneId: PaneID
    let onCreateTerminal: () -> Void
    let onCreateBrowser: () -> Void
}

struct WorkspaceLayoutTabChromeSnapshot {
    let tab: WorkspaceLayout.Tab
    let contextMenuState: TabContextMenuState
    let isSelected: Bool
    let showsZoomIndicator: Bool
}

struct WorkspaceLayoutPaneChromeSnapshot {
    let paneId: PaneID
    let tabs: [WorkspaceLayoutTabChromeSnapshot]
    let selectedTabId: UUID?
    let isFocused: Bool
    let showSplitButtons: Bool
    let chromeRevision: UInt64
}

struct WorkspaceLayoutPaneRenderSnapshot {
    let paneId: PaneID
    let chrome: WorkspaceLayoutPaneChromeSnapshot
    let contentId: UUID
    let content: WorkspacePaneContent
}

struct WorkspaceLayoutViewportSnapshot {
    let paneId: PaneID
    let contentId: UUID
    let mountIdentity: WorkspacePaneMountIdentity
    let content: WorkspacePaneContent
    let frame: CGRect
}

struct WorkspaceLayoutSplitRenderSnapshot {
    let splitId: UUID
    let orientation: SplitOrientation
    let dividerPosition: CGFloat
    let animationOrigin: SplitAnimationOrigin?
    let first: WorkspaceLayoutRenderNodeSnapshot
    let second: WorkspaceLayoutRenderNodeSnapshot
}

indirect enum WorkspaceLayoutRenderNodeSnapshot {
    case pane(WorkspaceLayoutPaneRenderSnapshot)
    case split(WorkspaceLayoutSplitRenderSnapshot)

    var paneIds: Set<UUID> {
        switch self {
        case .pane(let pane):
            return [pane.paneId.id]
        case .split(let split):
            return split.first.paneIds.union(split.second.paneIds)
        }
    }

    var splitIds: Set<UUID> {
        switch self {
        case .pane:
            return []
        case .split(let split):
            return Set([split.splitId])
                .union(split.first.splitIds)
                .union(split.second.splitIds)
        }
    }
}

struct WorkspaceLayoutLocalDragSnapshot: Equatable {
    let tabId: TabID
    let sourcePaneId: PaneID
}

func workspaceLayoutEffectiveTabDropTargetIndex(
    rawTargetIndex: Int,
    tabIds: [TabID],
    paneId: PaneID,
    localTabDrag: WorkspaceLayoutLocalDragSnapshot?
) -> Int? {
    guard let localTabDrag,
          localTabDrag.sourcePaneId == paneId,
          let sourceIndex = tabIds.firstIndex(of: localTabDrag.tabId) else {
        return rawTargetIndex
    }

    if rawTargetIndex == sourceIndex || rawTargetIndex == sourceIndex + 1 {
        return nil
    }

    return rawTargetIndex
}

enum WorkspacePaneDropOverlayPhase: Equatable {
    case hidden
    case visible
    case hiding
}

struct WorkspacePaneDropOverlayPresentation: Equatable {
    let phase: WorkspacePaneDropOverlayPhase
    let zone: DropZone?
    let generation: UInt64

    static let hidden = WorkspacePaneDropOverlayPresentation(
        phase: .hidden,
        zone: nil,
        generation: 0
    )

    static func visible(zone: DropZone, generation: UInt64) -> WorkspacePaneDropOverlayPresentation {
        WorkspacePaneDropOverlayPresentation(
            phase: .visible,
            zone: zone,
            generation: generation
        )
    }

    static func hiding(zone: DropZone, generation: UInt64) -> WorkspacePaneDropOverlayPresentation {
        WorkspacePaneDropOverlayPresentation(
            phase: .hiding,
            zone: zone,
            generation: generation
        )
    }
}

struct WorkspacePaneDropOverlayCoordinator {
    private(set) var activeDropZones: [UUID: DropZone] = [:]
    private(set) var presentations: [UUID: WorkspacePaneDropOverlayPresentation] = [:]
    var nextGenerationValue: UInt64 = 1

    mutating func setZone(_ zone: DropZone, for paneId: PaneID) -> Bool {
        let key = paneId.id
        let previousZone = activeDropZones[key]
        let previousPresentation = presentations[key] ?? .hidden
        activeDropZones[key] = zone
        if previousPresentation.phase != .visible || previousPresentation.zone != zone {
            presentations[key] = .visible(zone: zone, generation: nextGeneration())
        }
        let nextPresentation = presentations[key] ?? .hidden
        return previousZone != zone || previousPresentation != nextPresentation
    }

    mutating func clearZone(for paneId: PaneID) -> Bool {
        let key = paneId.id
        let previousZone = activeDropZones.removeValue(forKey: key)
        let previousPresentation = presentations[key] ?? .hidden
        let lastZone = previousPresentation.zone ?? previousZone
        if let lastZone, previousPresentation.phase != .hiding {
            presentations[key] = .hiding(zone: lastZone, generation: nextGeneration())
        } else if lastZone == nil {
            presentations.removeValue(forKey: key)
        }
        let nextPresentation = presentations[key] ?? .hidden
        return previousZone != nil || previousPresentation != nextPresentation
    }

    mutating func clearZoneImmediately(for paneId: PaneID) -> Bool {
        let key = paneId.id
        let previousZone = activeDropZones.removeValue(forKey: key)
        let previousPresentation = presentations.removeValue(forKey: key) ?? .hidden
        return previousZone != nil || previousPresentation != .hidden
    }

    mutating func completeHide(for paneId: PaneID, generation: UInt64) -> Bool {
        let key = paneId.id
        guard let presentation = presentations[key],
              presentation.phase == .hiding,
              presentation.generation == generation else {
            return false
        }
        presentations.removeValue(forKey: key)
        return true
    }

    func activeDropZone(for paneId: PaneID) -> DropZone? {
        activeDropZones[paneId.id]
    }

    func overlayPresentation(for paneId: PaneID) -> WorkspacePaneDropOverlayPresentation {
        presentations[paneId.id] ?? .hidden
    }

    func viewportDropZones() -> [UUID: DropZone?] {
        activeDropZones.reduce(into: [:]) { partialResult, entry in
            partialResult[entry.key] = entry.value
        }
    }

    mutating func removePane(_ paneId: PaneID) {
        activeDropZones.removeValue(forKey: paneId.id)
        presentations.removeValue(forKey: paneId.id)
    }

    mutating func clearAll() {
        activeDropZones.removeAll()
        presentations.removeAll()
    }

    mutating func nextGeneration() -> UInt64 {
        defer { nextGenerationValue &+= 1 }
        return nextGenerationValue
    }
}

struct WorkspaceLayoutPresentationSnapshot {
    let appearance: WorkspaceLayoutConfiguration.Appearance
    let isInteractive: Bool
    let isMinimalMode: Bool
    let tabShortcutHintsEnabled: Bool
    let localTabDrag: WorkspaceLayoutLocalDragSnapshot?

    var isHandlingLocalTabDrag: Bool {
        localTabDrag != nil
    }
}

struct WorkspaceLayoutRenderSnapshot {
    let presentation: WorkspaceLayoutPresentationSnapshot
    let root: WorkspaceLayoutRenderNodeSnapshot
    let viewports: [WorkspaceLayoutViewportSnapshot]
}
