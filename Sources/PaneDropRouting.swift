import AppKit
import Bonsplit

enum PaneExternalFileDropRouting: Equatable {
    case agentPromptPaste
    case terminalPaste
    case filePreview
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
}

typealias TerminalPaneDropRouting = PaneDropRouting
