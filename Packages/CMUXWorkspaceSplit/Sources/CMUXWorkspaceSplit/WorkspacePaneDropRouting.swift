import CoreGraphics

struct WorkspacePaneDropZoneDecision: Equatable {
    let defaultZone: DropZone
    let finalZone: DropZone
    let targetPaneId: PaneID
    let sourcePaneId: PaneID?
    let remapReason: String?
}

enum WorkspacePaneDropRouting {
    static let padding: CGFloat = 4

    static func overlayFrame(for zone: DropZone, in size: CGSize) -> CGRect {
        switch zone {
        case .center:
            return CGRect(
                x: padding,
                y: padding,
                width: size.width - (padding * 2),
                height: size.height - (padding * 2)
            )
        case .left:
            return CGRect(
                x: padding,
                y: padding,
                width: (size.width / 2) - padding,
                height: size.height - (padding * 2)
            )
        case .right:
            return CGRect(
                x: size.width / 2,
                y: padding,
                width: (size.width / 2) - padding,
                height: size.height - (padding * 2)
            )
        case .top:
            return CGRect(
                x: padding,
                y: size.height / 2,
                width: size.width - (padding * 2),
                height: (size.height / 2) - padding
            )
        case .bottom:
            return CGRect(
                x: padding,
                y: padding,
                width: size.width - (padding * 2),
                height: (size.height / 2) - padding
            )
        }
    }

    static func zone(for location: CGPoint, in size: CGSize) -> DropZone {
        let edgeRatio: CGFloat = 0.25
        let horizontalEdge = max(80, size.width * edgeRatio)
        let verticalEdge = max(80, size.height * edgeRatio)

        if location.x < horizontalEdge {
            return .left
        }
        if location.x > size.width - horizontalEdge {
            return .right
        }
        if location.y > size.height - verticalEdge {
            return .top
        }
        if location.y < verticalEdge {
            return .bottom
        }
        return .center
    }

    static func decision(
        for location: CGPoint,
        in size: CGSize,
        targetPaneId: PaneID,
        sourcePaneId: PaneID?
    ) -> WorkspacePaneDropZoneDecision {
        let defaultZone = zone(for: location, in: size)
        return WorkspacePaneDropZoneDecision(
            defaultZone: defaultZone,
            finalZone: defaultZone,
            targetPaneId: targetPaneId,
            sourcePaneId: sourcePaneId,
            remapReason: nil
        )
    }
}
