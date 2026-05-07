import AppKit
import Bonsplit

enum PaneExternalFileDropRouting: Equatable {
    case agentPromptPaste
    case terminalPaste
    case filePreview
}

struct PaneFileDropHint: Equatable {
    enum Action: Equatable {
        case filePreview
        case terminalPath
    }

    enum ModifierPrompt: Equatable {
        case holdShift
        case releaseShift
    }

    let currentAction: Action
    let modifierPrompt: ModifierPrompt
    let alternateAction: Action

    var displayText: String {
        switch (currentAction, modifierPrompt, alternateAction) {
        case (.filePreview, .holdShift, .terminalPath):
            return String(
                localized: "terminal.fileDropHint.previewHoldShiftTerminal",
                defaultValue: "Drop to open in editor. Hold Shift to insert path."
            )
        case (.filePreview, .releaseShift, .terminalPath):
            return String(
                localized: "terminal.fileDropHint.previewReleaseShiftTerminal",
                defaultValue: "Drop to open in editor. Release Shift to insert path."
            )
        case (.terminalPath, .holdShift, .filePreview):
            return String(
                localized: "terminal.fileDropHint.terminalHoldShiftPreview",
                defaultValue: "Drop to insert path. Hold Shift to open in editor."
            )
        case (.terminalPath, .releaseShift, .filePreview):
            return String(
                localized: "terminal.fileDropHint.terminalReleaseShiftPreview",
                defaultValue: "Drop to insert path. Release Shift to open in editor."
            )
        default:
            return String(
                localized: "terminal.fileDropHint.default",
                defaultValue: "Drop file. Hold Shift to use the alternate action."
            )
        }
    }
}

enum PaneDropRouting {
    static func externalFileDropRouting(
        panelType: PanelType,
        hostsAgent: Bool,
        defaultAction: TerminalFileDropSettings.Action,
        shiftKeyHeld: Bool
    ) -> PaneExternalFileDropRouting {
        guard panelType == .terminal else {
            return .filePreview
        }

        let effectiveAction = shiftKeyHeld ? defaultAction.inverted : defaultAction
        switch effectiveAction {
        case .filePreview:
            return .filePreview
        case .terminal:
            return hostsAgent ? .agentPromptPaste : .terminalPaste
        }
    }

    static func externalFileDropHint(
        panelType: PanelType,
        hostsAgent: Bool,
        defaultAction: TerminalFileDropSettings.Action,
        shiftKeyHeld: Bool
    ) -> PaneFileDropHint? {
        guard panelType == .terminal else { return nil }

        let current = hintAction(for: externalFileDropRouting(
            panelType: panelType,
            hostsAgent: hostsAgent,
            defaultAction: defaultAction,
            shiftKeyHeld: shiftKeyHeld
        ))
        let alternate = hintAction(for: externalFileDropRouting(
            panelType: panelType,
            hostsAgent: hostsAgent,
            defaultAction: defaultAction,
            shiftKeyHeld: !shiftKeyHeld
        ))
        guard current != alternate else { return nil }

        return PaneFileDropHint(
            currentAction: current,
            modifierPrompt: shiftKeyHeld ? .releaseShift : .holdShift,
            alternateAction: alternate
        )
    }

    static func zone(for location: CGPoint, in size: CGSize) -> DropZone {
        let edgeRatio: CGFloat = 0.25
        let horizontalEdge = max(80, size.width * edgeRatio)
        let verticalEdge = max(80, size.height * edgeRatio)

        if location.x < horizontalEdge {
            return .left
        } else if location.x > size.width - horizontalEdge {
            return .right
        } else if location.y > size.height - verticalEdge {
            return .top
        } else if location.y < verticalEdge {
            return .bottom
        } else {
            return .center
        }
    }

    static func filePreviewDestination(
        targetPane paneId: PaneID,
        zone: DropZone
    ) -> BonsplitController.ExternalTabDropRequest.Destination {
        switch zone {
        case .center:
            return .insert(targetPane: paneId, targetIndex: nil)
        case .left:
            return .split(targetPane: paneId, orientation: .horizontal, insertFirst: true)
        case .right:
            return .split(targetPane: paneId, orientation: .horizontal, insertFirst: false)
        case .top:
            return .split(targetPane: paneId, orientation: .vertical, insertFirst: true)
        case .bottom:
            return .split(targetPane: paneId, orientation: .vertical, insertFirst: false)
        }
    }

    static func overlayFrame(for zone: DropZone, in bounds: CGRect) -> CGRect {
        let midX = bounds.midX
        let midY = bounds.midY

        switch zone {
        case .center:
            return bounds.insetBy(dx: 10, dy: 10)
        case .left:
            return CGRect(x: bounds.minX + 8, y: bounds.minY + 8, width: max(0, midX - bounds.minX - 12), height: max(0, bounds.height - 16))
        case .right:
            return CGRect(x: midX + 4, y: bounds.minY + 8, width: max(0, bounds.maxX - midX - 12), height: max(0, bounds.height - 16))
        case .top:
            return CGRect(x: bounds.minX + 8, y: midY + 4, width: max(0, bounds.width - 16), height: max(0, bounds.maxY - midY - 12))
        case .bottom:
            return CGRect(x: bounds.minX + 8, y: bounds.minY + 8, width: max(0, bounds.width - 16), height: max(0, midY - bounds.minY - 12))
        }
    }

    private static func hintAction(for routing: PaneExternalFileDropRouting) -> PaneFileDropHint.Action {
        switch routing {
        case .agentPromptPaste:
            return .terminalPath
        case .terminalPaste:
            return .terminalPath
        case .filePreview:
            return .filePreview
        }
    }
}

typealias TerminalPaneDropRouting = PaneDropRouting
