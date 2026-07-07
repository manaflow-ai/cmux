import AppKit
import Bonsplit
import Foundation

struct PaneDropContext: Equatable {
    let workspaceId: UUID
    let panelId: UUID
    let paneId: PaneID
}

typealias TerminalPaneDropContext = PaneDropContext

struct PaneDragTransfer: Equatable {
    let tabId: UUID
    let sourcePaneId: UUID
    let sourceProcessId: Int32

    var isFromCurrentProcess: Bool {
        sourceProcessId == Int32(ProcessInfo.processInfo.processIdentifier)
    }

    static func decode(from pasteboard: NSPasteboard) -> PaneDragTransfer? {
        if let data = pasteboard.data(forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) {
            return decode(from: data)
        }
        if let raw = pasteboard.string(forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) {
            return decode(from: Data(raw.utf8))
        }
        return nil
    }

    static func decode(from data: Data) -> PaneDragTransfer? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tab = json["tab"] as? [String: Any],
              let tabIdRaw = tab["id"] as? String,
              let tabId = UUID(uuidString: tabIdRaw),
              let sourcePaneIdRaw = json["sourcePaneId"] as? String,
              let sourcePaneId = UUID(uuidString: sourcePaneIdRaw) else {
            return nil
        }

        let sourceProcessId = (json["sourceProcessId"] as? NSNumber)?.int32Value ?? -1
        return PaneDragTransfer(
            tabId: tabId,
            sourcePaneId: sourcePaneId,
            sourceProcessId: sourceProcessId
        )
    }
}

typealias TerminalPaneDragTransfer = PaneDragTransfer

@MainActor
enum PaneDropRoutingSession {
    private static var activeSequenceNumbers: Set<Int> = []

    static var hasActiveDropDrag: Bool {
        !activeSequenceNumbers.isEmpty
    }

    static func noteActiveDropDrag(_ sender: any NSDraggingInfo) {
        let types = sender.draggingPasteboard.types
        guard DragOverlayRoutingPolicy.hasBonsplitTabTransfer(types)
            || DragOverlayRoutingPolicy.hasFileDropPayload(types) else { return }
        activeSequenceNumbers.insert(sender.draggingSequenceNumber)
    }

    static func clearActiveDropDrag(_ sender: (any NSDraggingInfo)?) {
        guard let sender else {
            activeSequenceNumbers.removeAll()
            return
        }
        activeSequenceNumbers.remove(sender.draggingSequenceNumber)
    }
}

enum PaneDropRouting {
    private static func fullPaneSize(for size: CGSize, topChromeHeight: CGFloat) -> CGSize {
        CGSize(width: size.width, height: size.height + max(0, topChromeHeight))
    }

    static func zone(for location: CGPoint, in size: CGSize, topChromeHeight: CGFloat = 0) -> DropZone {
        let fullPaneSize = fullPaneSize(for: size, topChromeHeight: topChromeHeight)
        let edgeRatio: CGFloat = 0.25
        let horizontalEdge = max(80, fullPaneSize.width * edgeRatio)
        let verticalEdge = max(80, fullPaneSize.height * edgeRatio)

        if location.x < horizontalEdge {
            return .left
        } else if location.x > fullPaneSize.width - horizontalEdge {
            return .right
        } else if location.y > fullPaneSize.height - verticalEdge {
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

    static func overlayFrame(for zone: DropZone, in size: CGSize, topChromeHeight: CGFloat = 0) -> CGRect {
        overlayFrame(
            for: zone,
            in: CGRect(origin: .zero, size: fullPaneSize(for: size, topChromeHeight: topChromeHeight))
        )
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

    static func compactOverlayFrame(for zone: DropZone, in size: CGSize, topChromeHeight: CGFloat = 0) -> CGRect {
        compactOverlayFrame(
            for: zone,
            in: CGRect(origin: .zero, size: fullPaneSize(for: size, topChromeHeight: topChromeHeight))
        )
    }

    static func compactOverlayFrame(for zone: DropZone, in bounds: CGRect) -> CGRect {
        let padding: CGFloat = 4
        let midX = bounds.midX
        let midY = bounds.midY

        switch zone {
        case .center:
            return bounds.insetBy(dx: padding, dy: padding)
        case .left:
            return CGRect(x: bounds.minX + padding, y: bounds.minY + padding, width: max(0, midX - bounds.minX - padding), height: max(0, bounds.height - padding * 2))
        case .right:
            return CGRect(x: midX, y: bounds.minY + padding, width: max(0, bounds.maxX - midX - padding), height: max(0, bounds.height - padding * 2))
        case .top:
            return CGRect(x: bounds.minX + padding, y: midY, width: max(0, bounds.width - padding * 2), height: max(0, bounds.maxY - midY - padding))
        case .bottom:
            return CGRect(x: bounds.minX + padding, y: bounds.minY + padding, width: max(0, bounds.width - padding * 2), height: max(0, midY - bounds.minY - padding))
        }
    }
}

typealias TerminalPaneDropRouting = PaneDropRouting

@MainActor
final class PaneDropZoneOverlayAnimator {
    private let overlayView: NSView
    private var displayedZone: DropZone?
    private var animationGeneration: UInt64 = 0

    init(overlayView: NSView) {
        self.overlayView = overlayView
        Self.applyStyle(to: overlayView)
    }

    deinit {}

    static func applyStyle(to view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = cmuxAccentNSColor().withAlphaComponent(0.25).cgColor
        view.layer?.borderColor = cmuxAccentNSColor().cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 8
        view.isHidden = true
    }

    func hideImmediately() {
        displayedZone = nil
        animationGeneration &+= 1
        overlayView.layer?.removeAllAnimations()
        overlayView.isHidden = true
        overlayView.alphaValue = 1
    }

    func setZone(
        _ zone: DropZone?,
        frameForZone: (DropZone) -> CGRect,
        ensureAttached: () -> Void,
        bringToFront: () -> Void
    ) {
        let previousZone = displayedZone
        displayedZone = zone

        guard let zone else {
            guard !overlayView.isHidden else { return }
            animationGeneration &+= 1
            let generation = animationGeneration
            overlayView.layer?.removeAllAnimations()
            bringToFront()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                overlayView.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.animationGeneration == generation else { return }
                    guard self.displayedZone == nil else { return }
                    self.overlayView.isHidden = true
                    self.overlayView.alphaValue = 1
                }
            }
            return
        }

        ensureAttached()
        let targetFrame = frameForZone(zone)
        let needsFrameUpdate = !Self.rectApproximatelyEqual(overlayView.frame, targetFrame)
        let zoneChanged = previousZone != zone

        if !overlayView.isHidden && !needsFrameUpdate && !zoneChanged {
            bringToFront()
            return
        }

        animationGeneration &+= 1
        overlayView.layer?.removeAllAnimations()

        if overlayView.isHidden {
            applyFrame(targetFrame)
            overlayView.alphaValue = 0
            overlayView.isHidden = false
            bringToFront()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                overlayView.animator().alphaValue = 1
            }
            return
        }

        bringToFront()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if needsFrameUpdate {
                overlayView.animator().frame = targetFrame
            }
            if overlayView.alphaValue < 1 {
                overlayView.animator().alphaValue = 1
            }
        }
    }

    private func applyFrame(_ frame: CGRect) {
        guard !Self.rectApproximatelyEqual(overlayView.frame, frame) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlayView.frame = frame
        CATransaction.commit()
    }

    private static func rectApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }
}
