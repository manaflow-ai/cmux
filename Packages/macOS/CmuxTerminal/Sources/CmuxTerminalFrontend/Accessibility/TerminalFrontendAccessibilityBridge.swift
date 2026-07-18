internal import AppKit
internal import CmuxTerminalDomain

/// Demand-driven main-actor cache between AppKit AX queries and daemon snapshots.
@MainActor
final class TerminalFrontendAccessibilityBridge {
    private static let supportedSchemaVersion: UInt32 = 1

    private(set) weak var owner: TerminalFrontendInteractionView?
    private let linkOpener: @MainActor (String) -> Bool
    private var observationTask: Task<Void, Never>?
    private var demandStarted = false
    private var observedSnapshot: TerminalAccessibilitySnapshot?
    private var linkElements: [TerminalFrontendAccessibilityLinkElement] = []

    init(linkOpener: @escaping @MainActor (String) -> Bool) {
        self.linkOpener = linkOpener
    }

    deinit {
        observationTask?.cancel()
    }

    func bind(to owner: TerminalFrontendInteractionView) {
        precondition(self.owner == nil, "An accessibility bridge has one view owner")
        self.owner = owner
    }

    func stopObservation() {
        observationTask?.cancel()
        observationTask = nil
        demandStarted = false
        observedSnapshot = nil
        linkElements.removeAll(keepingCapacity: false)
    }

    func snapshot() -> TerminalAccessibilitySnapshot? {
        ensureDemand()
        guard let current = owner?.terminalAccessibilitySnapshot else {
            observedSnapshot = nil
            linkElements.removeAll(keepingCapacity: false)
            return nil
        }
        install(current, postNotifications: false)
        return observedSnapshot == current ? current : nil
    }

    func children() -> [Any] {
        guard snapshot() != nil else { return [] }
        return linkElements
    }

    func string(
        for range: TerminalAccessibilityRange,
        snapshot: TerminalAccessibilitySnapshot
    ) -> String? {
        guard isCurrent(snapshot) else { return nil }
        return TerminalFrontendAccessibilityTextModel(snapshot: snapshot).string(
            for: NSRange(location: range.location, length: range.length)
        )
    }

    func frame(
        for range: TerminalAccessibilityRange,
        snapshot: TerminalAccessibilitySnapshot
    ) -> NSRect {
        frame(
            for: NSRange(location: range.location, length: range.length),
            snapshot: snapshot
        ) ?? .zero
    }

    func frame(
        for range: NSRange,
        snapshot: TerminalAccessibilitySnapshot
    ) -> NSRect? {
        guard isCurrent(snapshot), let owner, let window = owner.window else { return nil }
        let model = TerminalFrontendAccessibilityTextModel(snapshot: snapshot)
        guard TerminalFrontendAccessibilityTextModel.isValid(
            range,
            maximum: model.utf16Length
        ) else { return nil }

        var localFrame = NSRect.null
        for cell in model.cells(intersecting: range) {
            guard let rect = cellRect(
                row: cell.row,
                column: cell.column,
                columnSpan: cell.columnSpan,
                snapshot: snapshot
            ) else { continue }
            localFrame = localFrame.isNull ? rect : localFrame.union(rect)
        }
        guard !localFrame.isNull else { return nil }
        return window.convertToScreen(owner.convert(localFrame, to: nil))
    }

    func range(
        forScreenPoint point: NSPoint,
        snapshot: TerminalAccessibilitySnapshot
    ) -> NSRange? {
        guard isCurrent(snapshot),
              let owner,
              let window = owner.window,
              let layout = layout(snapshot: snapshot)
        else { return nil }
        let windowPoint = window.convertFromScreen(
            NSRect(origin: point, size: .zero)
        ).origin
        let localPoint = owner.convert(windowPoint, from: nil)
        let column = Int(floor(
            (Double(localPoint.x) - Double(owner.bounds.minX) - layout.xInset)
                / layout.cellWidth
        ))
        let viewportRow = TerminalFrontendAccessibilityGeometry.unflippedViewportRow(
            localY: Double(localPoint.y),
            boundsMinimumY: Double(owner.bounds.minY),
            boundsHeight: Double(owner.bounds.height),
            yInset: layout.yInset,
            cellHeight: layout.cellHeight
        )
        guard column >= 0, column < snapshot.columns,
              viewportRow >= 0, viewportRow < snapshot.rows else { return nil }
        return TerminalFrontendAccessibilityTextModel(snapshot: snapshot).range(
            viewportRow: viewportRow,
            column: column
        )
    }

    /// Schedules one backend-revalidated link action and rejects stale children inline.
    func activate(
        link: TerminalAccessibilityLink,
        snapshot: TerminalAccessibilitySnapshot
    ) -> Bool {
        guard isCurrent(snapshot), snapshot.links.contains(link),
              let owner, owner.window != nil else {
            return false
        }
        Task { @MainActor [weak self, weak owner] in
            guard let self, let owner, self.isCurrent(snapshot),
                  let validated = await owner.activateTerminalAccessibilityLink(
                    link,
                    snapshot: snapshot
                  ),
                  validated == link.target,
                  self.isCurrent(snapshot),
                  owner.window != nil
            else { return }
            _ = self.linkOpener(validated)
        }
        return true
    }

    private func ensureDemand() {
        guard !demandStarted, let owner, owner.window != nil else { return }
        demandStarted = true
        owner.enableTerminalAccessibility()
        let snapshots = owner.terminalAccessibilitySnapshots()
        observationTask = Task { @MainActor [weak self, weak owner] in
            for await snapshot in snapshots {
                guard let self, let owner, !Task.isCancelled,
                      self.owner === owner else { return }
                self.install(snapshot, postNotifications: true)
            }
        }
    }

    private func install(
        _ snapshot: TerminalAccessibilitySnapshot,
        postNotifications: Bool
    ) {
        guard let owner,
              snapshot.schemaVersion == Self.supportedSchemaVersion,
              owner.terminalAccessibilitySnapshot == snapshot,
              isSuccessor(snapshot, of: observedSnapshot)
        else { return }

        let previous = observedSnapshot
        observedSnapshot = snapshot
        let model = TerminalFrontendAccessibilityTextModel(snapshot: snapshot)
        linkElements = snapshot.links.compactMap { link in
            let range = NSRange(
                location: link.utf16Range.location,
                length: link.utf16Range.length
            )
            guard TerminalFrontendAccessibilityTextModel.isValid(
                range,
                maximum: model.utf16Length
            ) else { return nil }
            return TerminalFrontendAccessibilityLinkElement(
                bridge: self,
                link: link,
                snapshot: snapshot
            )
        }

        guard postNotifications else { return }
        NSAccessibility.post(element: owner, notification: .valueChanged)
        if previous?.selections != snapshot.selections
            || previous?.cursor != snapshot.cursor {
            NSAccessibility.post(element: owner, notification: .selectedTextChanged)
        }
        if previous?.links != snapshot.links {
            NSAccessibility.post(element: owner, notification: .layoutChanged)
        }
        if previous?.focused != snapshot.focused {
            let element: Any = snapshot.focused
                ? owner
                : (owner.window?.firstResponder ?? owner)
            NSAccessibility.post(
                element: element,
                notification: .focusedUIElementChanged
            )
        }
    }

    private func isCurrent(_ snapshot: TerminalAccessibilitySnapshot) -> Bool {
        guard owner?.terminalAccessibilitySnapshot == snapshot else { return false }
        install(snapshot, postNotifications: false)
        return observedSnapshot == snapshot
    }

    private func isSuccessor(
        _ candidate: TerminalAccessibilitySnapshot,
        of previous: TerminalAccessibilitySnapshot?
    ) -> Bool {
        guard let previous else { return true }
        guard candidate.surfaceID == previous.surfaceID else { return false }
        if candidate.presentationID != previous.presentationID {
            return true
        }
        guard candidate.presentationGeneration >= previous.presentationGeneration else {
            return false
        }
        if candidate.presentationGeneration > previous.presentationGeneration {
            return true
        }

        let sameRevision = candidate.contentSequence == previous.contentSequence
            && candidate.terminalRevision == previous.terminalRevision
            && candidate.contentRevision == previous.contentRevision
            && candidate.viewportRevision == previous.viewportRevision
        guard !sameRevision else { return false }
        return candidate.contentSequence >= previous.contentSequence
            && candidate.terminalRevision >= previous.terminalRevision
            && candidate.contentRevision >= previous.contentRevision
            && candidate.viewportRevision >= previous.viewportRevision
    }

    private func layout(
        snapshot: TerminalAccessibilitySnapshot
    ) -> (cellWidth: Double, cellHeight: Double, xInset: Double, yInset: Double)? {
        guard let owner,
              let metrics = owner.interactionSnapshot.cellMetrics,
              metrics.columns == snapshot.columns,
              metrics.rows == snapshot.rows,
              metrics.columns > 0,
              metrics.rows > 0,
              metrics.cellWidthPixels > 0,
              metrics.cellHeightPixels > 0
        else { return nil }
        let scale = max(metrics.backingScale, 1)
        let cellWidth = Double(metrics.cellWidthPixels) / scale
        let cellHeight = Double(metrics.cellHeightPixels) / scale
        let gridWidth = Double(metrics.columns) * cellWidth
        let gridHeight = Double(metrics.rows) * cellHeight
        let xInset = metrics.paddingLeftPixels.map {
            max(Double($0) / scale, 0)
        } ?? max((Double(owner.bounds.width) - gridWidth) / 2, 0)
        let topInset = metrics.paddingTopPixels.map {
            max(Double($0) / scale, 0)
        } ?? max((Double(owner.bounds.height) - gridHeight) / 2, 0)
        return (
            cellWidth,
            cellHeight,
            xInset,
            topInset
        )
    }

    private func cellRect(
        row: UInt64,
        column: Int,
        columnSpan: Int,
        snapshot: TerminalAccessibilitySnapshot
    ) -> NSRect? {
        guard let owner,
              let layout = layout(snapshot: snapshot),
              row >= snapshot.viewportOffset,
              let viewportRow = Int(exactly: row - snapshot.viewportOffset),
              viewportRow >= 0,
              viewportRow < snapshot.rows,
              column >= 0,
              column < snapshot.columns
        else { return nil }
        return NSRect(
            x: Double(owner.bounds.minX) + layout.xInset
                + Double(column) * layout.cellWidth,
            y: TerminalFrontendAccessibilityGeometry.unflippedCellY(
                boundsMinimumY: Double(owner.bounds.minY),
                boundsHeight: Double(owner.bounds.height),
                yInset: layout.yInset,
                cellHeight: layout.cellHeight,
                viewportRow: viewportRow
            ),
            width: Double(max(columnSpan, 1)) * layout.cellWidth,
            height: layout.cellHeight
        )
    }
}
