import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import SwiftUI

/// Workspace reorder drop: planning the drop under the pointer and committing
/// it on release. The stored state stays on the controller.
extension SidebarWorkspaceTableController {
    func performReorderDrop(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target],
        payloadWorkspaceId: UUID?
    ) -> Bool {
        // A drop ends the drag: stop the pointer poll now, so a tick landing
        // before `endedAt` cannot re-lift the block the commit is placing.
        stopReorderPoll()
        reorderDragWindowPoint = nil
        guard let actions else {
            retireReorderIndicator()
            return false
        }
        let performed: Bool
        let commitSource: String
        if let plan = lastAcceptedReorderDropPlan {
            // Commit exactly what the indicator showed.
            performed = actions.commitWorkspaceDropPlan(plan)
            commitSource = "paintedPlan"
        } else {
            // No accepted hover plan exists: resolve from the release point.
            performed = actions.performWorkspaceDrop(point, targets, payloadWorkspaceId)
            commitSource = "releasePoint"
        }
#if DEBUG
        // Every silent "the workspace I dragged didn't move" report needs
        // this line: where the drop landed, which commit source ran, and
        // whether the shared planner accepted it.
        cmuxDebugLog(
            "sidebar.drop.perform point=(\(Int(point.x)),\(Int(point.y))) " +
            "source=\(commitSource) performed=\(performed ? 1 : 0)"
        )
#endif
        // A handled drop on the block's own slot moves nothing, so no
        // structural apply will come to take the transforms over. The lift
        // knows: no other row is displaced. Glide home now, rather than
        // waiting (non-structural applies can land first after any drop).
        let liftShowsMove = reorderLiftSession?.appliedTargets.contains { $0 != 0 } ?? false
        if performed && !liftShowsMove {
            suppressSelectedScrollAfterLocalDrop = true
            endReorderLift(animated: true)
        } else if performed {
            suppressSelectedScrollAfterLocalDrop = true
            // The rows already stand at their new positions via transforms;
            // the apply that lands the committed order clears them in the
            // same update, so the real frames take over in place.
            clearsReorderTransformsOnNextApply = true
            // Bounded fallback if the committed order never arrives, so the
            // rows are not left frozen where the lift drew them. Injected
            // clock with cancellation: the hand-off apply and the next drag
            // begin both cancel it.
            reorderDropCommitFallbackTask?.cancel()
            reorderDropCommitFallbackTask = Task { [weak self, previewBailoutClock] in
                try? await previewBailoutClock.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.clearsReorderTransformsOnNextApply else { return }
                self.reorderDropCommitFallbackTask = nil
                self.clearsReorderTransformsOnNextApply = false
                self.endReorderLift(animated: true)
            }
        } else {
            endReorderLift(animated: true)
        }
        retireReorderIndicator()
        return performed
    }

    func reorderDropDragExited() {
#if DEBUG
        cmuxDebugLog("sidebar.reorder.exited")
#endif
        // Visual-inert on purpose: destination exit fires at churn rate
        // whenever the plan goes nil (the overlay's operation flips to none
        // and AppKit re-resolves the destination). The poll owns the
        // visuals; the session ends only at endedAt.
        reorderDragPayloadWorkspaceId = nil
        guard reorderDragWindowPoint != nil || reorderIndicatorPainter != nil else { return }
        reorderDragWindowPoint = nil
        retireReorderIndicator()
    }

    /// Runs the shared reorder planner for a drag hovering at `windowPoint`
    /// and paints the resulting indicator. An accepted position is remembered
    /// (window space) so viewport changes can re-plan it; a rejected one
    /// stops the re-plan loop until the pointer produces a new overlay update.
    @discardableResult
    func updateReorderDrag(windowPoint: NSPoint) -> Bool {
        guard let dropView = containerView?.reorderDropView else {
            reorderDragWindowPoint = nil
            retireReorderIndicator()
            return false
        }
        let targets = refreshReorderDropTargets()
        return updateReorderDrag(
            point: dropView.convert(windowPoint, from: nil),
            targets: targets,
            windowPoint: windowPoint,
            payloadWorkspaceId: reorderDragPayloadWorkspaceId
        )
    }

    func updateReorderDrag(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target],
        windowPoint: NSPoint,
        payloadWorkspaceId: UUID?
    ) -> Bool {
        guard let actions else {
            reorderDragWindowPoint = nil
            retireReorderIndicator()
            return false
        }
        let reorderTickStart = ProcessInfo.processInfo.systemUptime
        defer {
            SidebarNavigationTimings.recordSampledTick("reorder.tick", startUptime: reorderTickStart)
        }
        reorderDragPayloadWorkspaceId = payloadWorkspaceId
        // Plan at the lifted block's slot probe, not the raw pointer, so the
        // committed gap is the one the displaced rows are showing.
        var plannerPoint = point
        if let session = reorderLiftSession, let containerView {
            let table = containerView.tableView
            let tablePoint = table.convert(windowPoint, from: nil)
            let placement = reorderLiftPlacement(session, pointY: tablePoint.y, tableMaxY: table.bounds.maxY)
            let probeWindowPoint = table.convert(NSPoint(x: tablePoint.x, y: placement.slotProbeY), to: nil)
            plannerPoint = containerView.reorderDropView.convert(probeWindowPoint, from: nil)
        }
        guard !targets.isEmpty,
              let update = actions.updateWorkspaceDrag(
                  plannerPoint,
                  targets,
                  payloadWorkspaceId
              )
        else {
            reorderDragWindowPoint = nil
            retireReorderIndicator()
#if DEBUG
            cmuxDebugLog("sidebar.reorder.plan-nil payload=\(payloadWorkspaceId?.uuidString.prefix(5) ?? "none")")
#endif
            // No legal gap at this point (commonly: hovering the dragged
            // row's own slot). Harmless: the poll owns the visuals, and this
            // callback owns only the plan.
            return false
        }
        // The plan is still tracked exactly as stock (the release commits
        // it), but it is drawn as displacement, not indicator lines: the
        // rows shifting around the lifted row are the drop preview.
        lastAcceptedReorderDropPlan = update.plan
        hasLiveReorderDropUpdate = true
        if case .reorder(_, _, let explicitGroupId)? = update.plan?.action {
            updateReorderLiftIndent(isGrouped: explicitGroupId != nil)
        }
        reorderDragWindowPoint = windowPoint
#if DEBUG
        cmuxDebugLog("sidebar.reorder.tick y=\(Int(point.y))")
#endif
        return true
    }

    func retireReorderIndicator() {
        lastAcceptedReorderDropPlan = nil
        let hadLiveUpdate = hasLiveReorderDropUpdate
        hasLiveReorderDropUpdate = false
        guard reorderIndicatorPainter != nil || hadLiveUpdate else { return }
        reorderIndicatorPainter = nil
        clearReorderIndicatorPaintOnVisibleCells()
        actions?.clearWorkspaceDropIndicator()
        setAppKitDropIndicator(nil, scope: .raw, includeRowTargets: false)
    }

    func enforceReorderIndicatorPaintOnVisibleCells() {
        guard reorderIndicatorPainter != nil else { return }
        sweepReorderIndicatorPaint(reorderIndicatorPainter)
    }

    func clearReorderIndicatorPaintOnVisibleCells() {
        sweepReorderIndicatorPaint(nil)
    }

    /// A nil painter clears every visible drop line, which is only safe here
    /// because reorder and bonsplit drags cannot overlap: outside a reorder
    /// drag the row models carry `false` for both flags, so clearing matches
    /// what the next configure would apply anyway.
    func sweepReorderIndicatorPaint(
        _ painter: SidebarWorkspaceTableReorderIndicatorPainter?
    ) {
        guard let table = containerView?.tableView else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.lowerBound..<(visible.lowerBound + visible.length)
        where rows.indices.contains(row) {
            let paint = painter?.paint(forRowWorkspaceId: rows[row].workspaceId)
                ?? (top: false, bottom: false)
            switch table.view(atColumn: 0, row: row, makeIfNecessary: false) {
            case let cell as SidebarWorkspaceRowTableCellView:
                cell.paintControllerDropIndicator(top: paint.top, bottom: paint.bottom)
            case let cell as SidebarGroupHeaderTableCellView:
                cell.paintControllerDropIndicator(top: paint.top, bottom: paint.bottom)
            default:
                break
            }
        }
    }

    /// Refreshes visible-row targets in the overlay's coordinate space.
    @discardableResult
    func refreshReorderDropTargets() -> [SidebarWorkspaceReorderDropOverlay.Target] {
        guard let container = containerView else { return [] }
        let table = container.tableView
        let visibleRange = table.rows(in: table.visibleRect)
        guard visibleRange.location != NSNotFound, visibleRange.length > 0 else {
            clearReorderDropTargets()
            return []
        }
        let lower = max(0, visibleRange.location)
        let upper = min(rows.count, visibleRange.location + visibleRange.length)
        guard lower < upper else {
            clearReorderDropTargets()
            return []
        }
        let targets = (lower..<upper).map { row in
            let configuration = rows[row]
            return SidebarWorkspaceReorderDropOverlay.Target(
                workspaceId: configuration.workspaceId,
                groupId: configuration.groupId,
                isGroupHeader: configuration.isGroupHeader,
                frame: table.convert(table.rect(ofRow: row), to: container.reorderDropView)
            )
        }
        container.reorderDropView.targets = targets
        container.reorderDropView.targetsDidUpdate()
        return targets
    }

    func clearReorderDropTargets() {
        guard let reorderDropView = containerView?.reorderDropView else { return }
        reorderDropView.targets = []
        reorderDropView.targetsDidUpdate()
    }

    /// Item-provider drag sources promise data rather than strings, so fall
    /// back to a UTF-8 decode of the raw data when `string(forType:)` is nil.
    static func reorderPayloadWorkspaceId(_ pasteboard: NSPasteboard) -> UUID? {
        let type = NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)
        let raw = pasteboard.string(forType: type)
            ?? pasteboard.data(forType: type).flatMap { String(data: $0, encoding: .utf8) }
        let parsed = SidebarTabDragPayload.workspaceId(fromPasteboardString: raw)
#if DEBUG
        cmuxDebugLog(
            "sidebar.drop.payload raw=\(raw.map { String($0.prefix(24)) } ?? "nil") " +
            "parsed=\(parsed.map { String($0.uuidString.prefix(5)) } ?? "nil")"
        )
#endif
        return parsed
    }

    func workspaceDragImage(
        tableView: NSTableView,
        row: Int,
        size: NSSize,
        count: Int
    ) -> NSImage? {
        guard size.width > 0, size.height > 0,
              let rowImage = reorderRowImage(tableView: tableView, row: row) else { return nil }
        let badgeColor = (AppDelegate.shared?.accentColor ?? CmuxAccentColor()).nsColor(for: tableView.effectiveAppearance)

        return NSImage(size: size, flipped: false) { bounds in
            rowImage.draw(in: bounds)

            let badgeDiameter: CGFloat = 18
            let badgeInset: CGFloat = 2
            let badgeRect = NSRect(
                x: bounds.maxX - badgeDiameter - badgeInset,
                y: bounds.maxY - badgeDiameter - badgeInset,
                width: badgeDiameter,
                height: badgeDiameter
            )
            badgeColor.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()

            let countText = "\(count)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let textSize = countText.size(withAttributes: attributes)
            countText.draw(
                at: NSPoint(
                    x: badgeRect.midX - (textSize.width / 2),
                    y: badgeRect.midY - (textSize.height / 2)
                ),
                withAttributes: attributes
            )
            return true
        }
    }
}
