import CmuxFoundation
import AppKit
import Bonsplit
import Foundation

@MainActor
extension AppDelegate {
    /// Revokes Bonsplit routing after a destination accepts the drop.
    ///
    /// The native source remains retained until AppKit delivers its terminal
    /// `endedAt` callback; this call must not release that source early.
    func finishAcceptedBonsplitTabDrop(
        from pasteboard: NSPasteboard = NSPasteboard(name: .drag)
    ) {
        tabDragTransferRegistry.finish(from: pasteboard)
        liveTabDragCapabilityResolver.invalidate()
    }
}

struct PaneDropContext: Equatable {
    let workspaceId: UUID
    let panelId: UUID
    let paneId: PaneID
    /// Whether the target pane is owned by a right-sidebar Dock rather than a
    /// workspace's main Bonsplit tree. This travels with the pane snapshot so
    /// portal hit-testing does not depend on a transient global lookup.
    let isDockHosted: Bool

    init(
        workspaceId: UUID,
        panelId: UUID,
        paneId: PaneID,
        isDockHosted: Bool = false
    ) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.paneId = paneId
        self.isDockHosted = isDockHosted
    }
}

typealias TerminalPaneDropContext = PaneDropContext

struct PaneDragTransfer: Equatable {
    let tabId: UUID
    let sourcePaneId: UUID
    let sourceProcessId: Int32
    let rightSidebarToolMode: RightSidebarMode?

    var isFromCurrentProcess: Bool {
        sourceProcessId == Int32(ProcessInfo.processInfo.processIdentifier)
    }

    init(tabDragTransfer: TabDragTransfer) {
        rightSidebarToolMode = RightSidebarToolDragPayload(transfer: tabDragTransfer)?.mode
        tabId = tabDragTransfer.tab.id.uuid
        sourcePaneId = tabDragTransfer.sourcePaneId.id
        sourceProcessId = Int32(ProcessInfo.processInfo.processIdentifier)
    }

    init(tabId: UUID, sourcePaneId: UUID, sourceProcessId: Int32) {
        rightSidebarToolMode = nil
        self.tabId = tabId
        self.sourcePaneId = sourcePaneId
        self.sourceProcessId = sourceProcessId
    }

    /// Decodes the legacy JSON representation used by older synthetic sources.
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
protocol PaneDropRoutingHost: AnyObject {
    var paneDropRoutingSession: PaneDropRoutingSession { get }
}

extension PaneDropRoutingHost {
    var hasActivePaneDropDrag: Bool {
        paneDropRoutingSession.hasActiveDropDrag
    }

    func updateActivePaneDropRoutingSession(_ sender: any NSDraggingInfo, operation: NSDragOperation) -> Bool {
        paneDropRoutingSession.updateActiveDropDrag(sender, operation: operation)
    }

    func clearActivePaneDropRoutingSession(_ sender: any NSDraggingInfo) {
        paneDropRoutingSession.clearActiveDropDrag(sender)
    }

    func clearActivePaneDropRoutingSession(sequenceNumber: Int) {
        paneDropRoutingSession.clearActiveDropDrag(sequenceNumber: sequenceNumber)
    }
}

extension WindowTerminalHostView: PaneDropRoutingHost {}
extension WindowBrowserHostView: PaneDropRoutingHost {}

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

    static func destination(
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

/// Shows, moves and hides a pane drop-zone highlight.
///
/// Moving between zones sets the model frame to the new zone at once, so layout
/// and hit geometry never trail the pointer, and draws the change as a slide:
/// additive offsets decay from the displayed frame to zero. Offsets stack, so a
/// retarget during a slide continues from where the highlight is drawn.
@MainActor
final class PaneDropZoneOverlayAnimator {
    enum Transition: Equatable {
        case unchanged
        case shown
        case moved
        case hidden
    }

    /// Short with a steep ease-out, so about half the distance is covered on
    /// the first frame and the highlight keeps pace with the pointer.
    private static let slideDuration: CFTimeInterval = 0.16
    private static let slideKeyPrefix = "paneDropZone.slide."

    /// Whether a new zone snaps instead of sliding; defaults to Reduce Motion.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private let overlayView: NSView
    private var displayedZone: DropZone?
    private var animationGeneration: UInt64 = 0
    /// The coordinate-space owner used for the last presented frame. A pane
    /// portal can reparent its overlay while a drag is active; a frame from
    /// the old owner must never become the starting point of a slide in the
    /// new owner.
    private weak var geometrySuperview: NSView?

    init(overlayView: NSView) {
        self.overlayView = overlayView
        Self.applyStyle(to: overlayView)
    }

    deinit {}

    static func applyStyle(to view: NSView) {
        view.wantsLayer = true
        let accent = (AppDelegate.shared?.accentColor ?? CmuxAccentColor()).themeNSColor
        view.layer?.backgroundColor = accent.withAlphaComponent(0.25).cgColor
        view.layer?.borderColor = accent.cgColor
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
        geometrySuperview = nil
    }

    /// Shows the highlight for `zone`, or fades it out for `nil`.
    ///
    /// `bringToFront` runs before any animation is added, so reordering the
    /// overlay never drops an in-flight slide.
    @discardableResult
    func setZone(
        _ zone: DropZone?,
        frameForZone: (DropZone) -> CGRect,
        ensureAttached: () -> Void,
        bringToFront: () -> Void
    ) -> Transition {
        let previousZone = displayedZone
        displayedZone = zone

        guard let zone else {
            bringToFront()
            // A visible overlay with no zone is already fading out.
            guard previousZone != nil, !overlayView.isHidden else { return .unchanged }
            animationGeneration &+= 1
            let generation = animationGeneration
            // In-flight slides keep running so the highlight fades where it is drawn.
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
            return .hidden
        }

        ensureAttached()
        let previousSuperview = geometrySuperview
        let currentSuperview = overlayView.superview
        let geometryOwnerChanged = previousSuperview != nil && previousSuperview !== currentSuperview
        geometrySuperview = currentSuperview
        let targetFrame = frameForZone(zone)
        bringToFront()
        let zoneChanged = previousZone != zone
        if !overlayView.isHidden && !zoneChanged && Self.rectApproximatelyEqual(overlayView.frame, targetFrame) {
            return .unchanged
        }

        animationGeneration &+= 1

        if overlayView.isHidden {
            overlayView.layer?.removeAllAnimations()
            snapFrame(targetFrame)
            overlayView.alphaValue = 0
            overlayView.isHidden = false
            fadeIn()
            return .shown
        }

        // A model frame has meaning only in its superview's coordinate space.
        // Reparenting during a portal handoff changes that space even when the
        // pane's logical zone is unchanged, so snap before any new animation.
        if geometryOwnerChanged {
            snapFrame(targetFrame)
            if overlayView.alphaValue < 1 {
                fadeIn()
            }
            return .moved
        }

        // A new zone slides; a reframe of the same zone follows layout at once.
        if zoneChanged && overlayView.window != nil && !reducesMotion() {
            slide(to: targetFrame)
        } else {
            snapFrame(targetFrame)
        }
        if overlayView.alphaValue < 1 {
            fadeIn()
        }
        return .moved
    }

    /// Moves the overlay straight to `frame` for a layout change. An in-flight
    /// slide is dropped, since its offsets were measured from the old layout.
    func snapFrame(_ frame: CGRect) {
        if let layer = overlayView.layer {
            for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.slideKeyPrefix) {
                layer.removeAnimation(forKey: key)
            }
        }
        guard !Self.rectApproximatelyEqual(overlayView.frame, frame) else { return }
        setModelFrame(frame)
    }

    private func setModelFrame(_ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlayView.frame = frame
        CATransaction.commit()
    }

    private func fadeIn() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            overlayView.animator().alphaValue = 1
        }
    }

    private func slide(to frame: CGRect) {
        let displayedFrame = overlayView.frame
        // Running slides stay, so the new offset stacks on where the overlay is drawn.
        setModelFrame(frame)
        guard let layer = overlayView.layer else { return }
        let sizeOffset = CGSize(
            width: displayedFrame.width - frame.width,
            height: displayedFrame.height - frame.height
        )
        // A layer's position is its frame origin plus anchorPoint × size.
        let anchor = layer.anchorPoint
        let positionOffset = CGPoint(
            x: displayedFrame.minX - frame.minX + anchor.x * sizeOffset.width,
            y: displayedFrame.minY - frame.minY + anchor.y * sizeOffset.height
        )
        if positionOffset != .zero {
            addSlide(to: layer, keyPath: "position", from: NSValue(point: positionOffset), to: NSValue(point: .zero))
        }
        if sizeOffset != .zero {
            addSlide(to: layer, keyPath: "bounds.size", from: NSValue(size: sizeOffset), to: NSValue(size: .zero))
        }
    }

    private func addSlide(to layer: CALayer, keyPath: String, from offset: NSValue, to zero: NSValue) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = offset
        animation.toValue = zero
        animation.isAdditive = true
        animation.duration = Self.slideDuration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        layer.add(animation, forKey: "\(Self.slideKeyPrefix)\(keyPath).\(animationGeneration)")
    }

    private static func rectApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }
}
