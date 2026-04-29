import AppKit
import Foundation

@MainActor
protocol WorkspaceLayoutDelegate: AnyObject {
    func workspaceSplit(shouldCreateTab tabId: TabID, inPane pane: PaneID) -> Bool
    func workspaceSplit(shouldCloseTab tabId: TabID, inPane pane: PaneID) -> Bool
    func workspaceSplit(didCreateTab tabId: TabID, inPane pane: PaneID)
    func workspaceSplit(didCloseTab tabId: TabID, fromPane pane: PaneID)
    func workspaceSplit(didSelectTab tabId: TabID, inPane pane: PaneID)
    func workspaceSplit(didMoveTab tabId: TabID, fromPane source: PaneID, toPane destination: PaneID)
    func workspaceSplit(shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool
    func workspaceSplit(shouldClosePane pane: PaneID) -> Bool
    func workspaceSplit(didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation)
    func workspaceSplit(didClosePane paneId: PaneID)
    func workspaceSplit(didFocusPane pane: PaneID)
    func workspaceSplit(didRequestNewTab kind: WorkspaceLayoutTabKind, inPane pane: PaneID)
    func workspaceSplit(didRequestTabContextAction action: TabContextAction, for tabId: TabID, inPane pane: PaneID)
}

struct WorkspacePanelPresentationFacts: Equatable, Sendable {
    let paneId: PaneID
    let panelId: UUID
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let isSelectedInPane: Bool
    let isFocused: Bool

    var isVisibleInUI: Bool {
        guard isWorkspaceVisible else { return false }
        return isSelectedInPane || isFocused
    }

    var wantsFirstResponder: Bool {
        isVisibleInUI && isWorkspaceInputActive && isFocused
    }
}

enum WorkspaceTerminalPresentationOperation: Equatable, Sendable {
    case setVisibleInUI(Bool)
    case setActive(Bool)
    case requestFirstResponderReconcile
}

struct WorkspaceTerminalPresentationState: Equatable, Sendable {
    let isVisibleInUI: Bool
    let isActive: Bool

    var wantsFirstResponder: Bool {
        isVisibleInUI && isActive
    }
}

enum WorkspaceTerminalPresentationTransitionResolver {
    static func operations(
        previous: WorkspaceTerminalPresentationState?,
        next: WorkspaceTerminalPresentationState
    ) -> [WorkspaceTerminalPresentationOperation] {
        var operations: [WorkspaceTerminalPresentationOperation] = []

        if previous?.isVisibleInUI != next.isVisibleInUI {
            operations.append(.setVisibleInUI(next.isVisibleInUI))
        }

        if previous?.isActive != next.isActive {
            operations.append(.setActive(next.isActive))
        }

        if next.wantsFirstResponder && previous?.wantsFirstResponder != true {
            operations.append(.requestFirstResponderReconcile)
        }

        return operations
    }
}

extension WorkspaceLayoutDelegate {
    func workspaceSplit(shouldCreateTab tabId: TabID, inPane pane: PaneID) -> Bool { true }
    func workspaceSplit(shouldCloseTab tabId: TabID, inPane pane: PaneID) -> Bool { true }
    func workspaceSplit(didCreateTab tabId: TabID, inPane pane: PaneID) {}
    func workspaceSplit(didCloseTab tabId: TabID, fromPane pane: PaneID) {}
    func workspaceSplit(didSelectTab tabId: TabID, inPane pane: PaneID) {}
    func workspaceSplit(didMoveTab tabId: TabID, fromPane source: PaneID, toPane destination: PaneID) {}
    func workspaceSplit(shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool { true }
    func workspaceSplit(shouldClosePane pane: PaneID) -> Bool { true }
    func workspaceSplit(didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {}
    func workspaceSplit(didClosePane paneId: PaneID) {}
    func workspaceSplit(didFocusPane pane: PaneID) {}
    func workspaceSplit(didRequestNewTab kind: WorkspaceLayoutTabKind, inPane pane: PaneID) {}
    func workspaceSplit(didRequestTabContextAction action: TabContextAction, for tabId: TabID, inPane pane: PaneID) {}
}
extension WorkspaceTabID {
    init(id: UUID) {
        self.rawValue = id
    }

    var id: UUID {
        rawValue
    }
}

extension WorkspaceDropZone {
    var insertsFirst: Bool {
        insertFirst
    }
}
