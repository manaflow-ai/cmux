import AppKit
import CmuxTerminalCore
import Foundation

@MainActor
extension GhosttySurfaceScrollView {
    var notificationScrollPosition: TerminalNotificationScrollPosition? {
        guard let geometry = surfaceView.authoritativeScrollbarGeometry() else { return nil }
        guard let anchor = TerminalScrollbackViewportAnchor(scrollbar: geometry.scrollbar) else { return nil }
        return TerminalNotificationScrollPosition(
            row: anchor.rowsBelowViewport,
            totalRows: anchor.capturedTotalRows,
            rowSpaceRevision: geometry.rowSpaceRevision
        )
    }

    @discardableResult
    func restoreNotificationScrollPosition(_ position: TerminalNotificationScrollPosition?) -> Bool {
        guard let position else {
            clearPendingNotificationScrollRestore()
            return false
        }

        switch notificationScrollRestoreState.replay {
        case .armed, .replaying:
            notificationScrollRestoreState.request = .waitingForReplay(
                position: position,
                attemptsRemaining: 2
            )
            return false
        case .completedAwaitingGeometry
            where position.row != 0 || position.rowSpaceRevision == nil:
            notificationScrollRestoreState.request = .waitingForReplay(
                position: position,
                attemptsRemaining: 2
            )
            return false
        case .completed(let geometry)
            where position.rowSpaceRevision == nil ||
                (position.row != 0 && position.rowSpaceRevision != geometry.rowSpaceRevision):
            notificationScrollRestoreState.request = .awaitingPostReplayRestore(
                position: position,
                attemptsRemaining: 2,
                replayContext: .stable(geometry)
            )
        case .inactive, .armedAfterExplicitInput, .replayingAfterExplicitInput,
             .completedAwaitingGeometry, .completed:
            notificationScrollRestoreState.request = .awaitingInitialGeometry(
                position: position,
                attemptsRemaining: 2
            )
        }
        return restorePendingNotificationScrollPositionIfReady()
    }

    @discardableResult
    func restorePendingNotificationScrollPositionIfReady(
        authoritativeGeometry: NotificationScrollRestoreGeometry? = nil
    ) -> Bool {
        if case .completedAwaitingGeometry = notificationScrollRestoreState.replay,
           let geometry = authoritativeGeometry ?? surfaceView.authoritativeScrollbarGeometry() {
            notificationScrollRestoreState.replay = .completed(geometry)
            configureWaitingRequestAfterReplay(using: geometry)
        }

        switch notificationScrollRestoreState.request {
        case .idle, .waitingForReplay:
            return false
        case .awaitingInitialGeometry(let position, let attemptsRemaining):
            return restoreInitialNotificationScrollPosition(
                position,
                attemptsRemaining: attemptsRemaining
            )
        case .awaitingPostReplayRestore(
            let position,
            let attemptsRemaining,
            let replayContext
        ):
            return restorePostReplayNotificationScrollPosition(
                position,
                attemptsRemaining: attemptsRemaining,
                authoritativeGeometry: authoritativeGeometry,
                replayContext: replayContext
            )
        }
    }

    private func configureWaitingRequestAfterReplay(
        using geometry: NotificationScrollRestoreGeometry
    ) {
        guard case .waitingForReplay(let position, let attemptsRemaining) =
            notificationScrollRestoreState.request else { return }
        if position.rowSpaceRevision == nil ||
            (position.row != 0 && position.rowSpaceRevision != geometry.rowSpaceRevision) {
            notificationScrollRestoreState.request = .awaitingPostReplayRestore(
                position: position,
                attemptsRemaining: attemptsRemaining,
                replayContext: .provisional(geometry)
            )
        } else {
            notificationScrollRestoreState.request = .awaitingInitialGeometry(
                position: position,
                attemptsRemaining: attemptsRemaining
            )
        }
    }

    private func restoreInitialNotificationScrollPosition(
        _ position: TerminalNotificationScrollPosition,
        attemptsRemaining: Int
    ) -> Bool {
        guard attemptsRemaining > 0 else {
            clearPendingNotificationScrollRestore()
            return false
        }
        guard let geometry = surfaceView.authoritativeScrollbarGeometry() else { return false }
        guard geometry.scrollbar.len > 0 else { return false }
        if let capturedRevision = position.rowSpaceRevision,
           position.row != 0,
           capturedRevision != geometry.rowSpaceRevision {
            clearPendingNotificationScrollRestore()
            return false
        }
        guard let targetTopRow = targetTopRow(
            for: position,
            in: geometry.scrollbar,
            rebaseToCurrentRows: false
        ) else {
            clearPendingNotificationScrollRestore()
            return false
        }

        return applyNotificationScrollRestore(
            targetTopRow: targetTopRow,
            scrollbar: geometry.scrollbar,
            attemptsRemaining: attemptsRemaining,
            requiresLiveBottom: position.row == 0,
            perform: {
                self.surfaceView.scrollToRow(
                    targetTopRow,
                    ifRowSpaceRevisionMatches: position.row == 0
                        ? geometry.rowSpaceRevision
                        : position.rowSpaceRevision ?? geometry.rowSpaceRevision
                )
            },
            pendingRequest: { remaining in
                .awaitingInitialGeometry(position: position, attemptsRemaining: remaining)
            }
        )
    }

    private func restorePostReplayNotificationScrollPosition(
        _ position: TerminalNotificationScrollPosition,
        attemptsRemaining: Int,
        authoritativeGeometry: NotificationScrollRestoreGeometry?,
        replayContext: NotificationReplayRestoreContext
    ) -> Bool {
        guard attemptsRemaining > 0 else {
            clearPendingNotificationScrollRestore()
            return false
        }
        let currentGeometry = surfaceView.authoritativeScrollbarGeometry()
        guard let replayGeometry = position.row == 0
            ? currentGeometry
            : authoritativeGeometry ?? currentGeometry else {
            return false
        }
        let geometry = currentGeometry ?? replayGeometry
        let anchorGeometry: NotificationScrollRestoreGeometry
        let retryReplayContext: NotificationReplayRestoreContext
        if position.row != 0,
           replayContext.geometry.rowSpaceRevision != geometry.rowSpaceRevision {
            switch replayContext {
            case .provisional:
                anchorGeometry = geometry
                retryReplayContext = .provisional(geometry)
            case .stable where position.rowSpaceRevision == geometry.rowSpaceRevision:
                anchorGeometry = geometry
                retryReplayContext = .stable(geometry)
            case .stable:
                clearPendingNotificationScrollRestore()
                return false
            }
        } else {
            anchorGeometry = replayContext.geometry
            retryReplayContext = replayContext
        }
        let anchorScrollbar = position.row == 0
            ? geometry.scrollbar
            : GhosttyScrollbar(
                total: anchorGeometry.scrollbar.total,
                offset: anchorGeometry.scrollbar.offset,
                len: currentGeometry?.scrollbar.len ?? geometry.scrollbar.len
            )
        let shouldRebase = position.totalRows.map {
            Int(clamping: anchorScrollbar.total) != $0
        } == true
        guard let targetTopRow = targetTopRow(
            for: position,
            in: anchorScrollbar,
            rebaseToCurrentRows: shouldRebase
        ) else {
            return false
        }

        return applyNotificationScrollRestore(
            targetTopRow: targetTopRow,
            scrollbar: geometry.scrollbar,
            attemptsRemaining: attemptsRemaining,
            requiresLiveBottom: position.row == 0,
            perform: {
                self.surfaceView.scrollToRow(
                    targetTopRow,
                    ifRowSpaceRevisionMatches: position.row == 0
                        ? geometry.rowSpaceRevision
                        : anchorGeometry.rowSpaceRevision
                )
            },
            pendingRequest: { remaining in
                return .awaitingPostReplayRestore(
                    position: position,
                    attemptsRemaining: remaining,
                    replayContext: retryReplayContext
                )
            }
        )
    }

    private func targetTopRow(
        for position: TerminalNotificationScrollPosition,
        in scrollbar: GhosttyScrollbar,
        rebaseToCurrentRows: Bool
    ) -> Int? {
        let currentTotalRows = Int(clamping: scrollbar.total)
        let capturedTotalRows = rebaseToCurrentRows
            ? currentTotalRows
            : position.totalRows ?? currentTotalRows
        return TerminalScrollbackViewportAnchor(
            rowsBelowViewport: position.row,
            capturedTotalRows: capturedTotalRows
        ).topRow(in: scrollbar)
    }

    private func applyNotificationScrollRestore(
        targetTopRow: Int,
        scrollbar: GhosttyScrollbar,
        attemptsRemaining: Int,
        requiresLiveBottom: Bool,
        perform: () -> NotificationScrollRestoreGeometry?,
        pendingRequest: (Int) -> NotificationScrollRequestPhase
    ) -> Bool {
        let currentLastTopRow = Int(clamping: scrollbar.total - min(scrollbar.total, scrollbar.len))
        let previousScrollIntent = prepareExplicitViewportRestore(
            isAtBottom: targetTopRow >= currentLastTopRow
        )
        let restoredGeometry = perform()
        var didRestore = restoredGeometry != nil
        if requiresLiveBottom, let restoredGeometry {
            // Output appended during the atomic scroll moves the live bottom
            // below the row we just landed on; keep the request pending so the
            // next scrollbar update re-anchors to the new bottom.
            let restoredScrollbar = restoredGeometry.scrollbar
            let restoredLastTopRow = Int(clamping: restoredScrollbar.total
                - min(restoredScrollbar.total, restoredScrollbar.len))
            if targetTopRow < restoredLastTopRow {
                didRestore = false
            }
        }
        if didRestore {
            clearPendingNotificationScrollRestore()
        } else {
            rollbackExplicitViewportRestore(to: previousScrollIntent)
            let remainingAfterAttempt = attemptsRemaining - 1
            if remainingAfterAttempt == 0 {
                clearPendingNotificationScrollRestore()
            } else {
                notificationScrollRestoreState.request = pendingRequest(remainingAfterAttempt)
            }
        }
        return didRestore
    }

    func clearPendingNotificationScrollRestore() {
        notificationScrollRestoreState.request = .idle
    }

    func cancelPendingNotificationScrollRestoreForUserInput() {
        switch notificationScrollRestoreState.replay {
        case .armed(let expectedStartBoundary, let expectedEndBoundary):
            notificationScrollRestoreState.replay = .armedAfterExplicitInput(
                expectedStartBoundary: expectedStartBoundary,
                expectedEndBoundary: expectedEndBoundary
            )
        case .replaying(let expectedEndBoundary):
            notificationScrollRestoreState.replay = .replayingAfterExplicitInput(
                expectedEndBoundary: expectedEndBoundary
            )
        case .armedAfterExplicitInput, .replayingAfterExplicitInput:
            break
        case .inactive, .completedAwaitingGeometry, .completed:
            break
        }
        clearPendingNotificationScrollRestore()
    }

    func armSessionScrollbackReplay(expectedStartBoundary: String, expectedEndBoundary: String) {
        surfaceView.registerNotificationScrollReplayBoundaries(
            startBoundary: expectedStartBoundary,
            endBoundary: expectedEndBoundary
        )
        notificationScrollRestoreState.replay = .armed(
            expectedStartBoundary: expectedStartBoundary,
            expectedEndBoundary: expectedEndBoundary
        )
        if let position = notificationScrollRestoreState.pendingPosition {
            notificationScrollRestoreState.request = .waitingForReplay(
                position: position,
                attemptsRemaining: 2
            )
        }
    }

    func armSessionScrollbackReplay(from environment: [String: String]) {
        guard let path = environment[SessionScrollbackReplayStore.environmentKey] else { return }
        armSessionScrollbackReplay(
            expectedStartBoundary: SessionScrollbackReplayStore.startBoundaryValue(forReplayFilePath: path),
            expectedEndBoundary: SessionScrollbackReplayStore.endBoundaryValue(forReplayFilePath: path)
        )
    }

    @discardableResult
    func sessionScrollbackReplayDidReceiveBoundary(
        _ boundary: String,
        authoritativeGeometry: NotificationScrollRestoreGeometry? = nil
    ) -> Bool {
        switch notificationScrollRestoreState.replay {
        case .armed(let expectedStartBoundary, let expectedEndBoundary)
            where boundary == expectedStartBoundary:
            notificationScrollRestoreState.replay = .replaying(
                expectedEndBoundary: expectedEndBoundary
            )
            return true
        case .armedAfterExplicitInput(let expectedStartBoundary, let expectedEndBoundary)
            where boundary == expectedStartBoundary:
            notificationScrollRestoreState.replay = .replayingAfterExplicitInput(
                expectedEndBoundary: expectedEndBoundary
            )
            return true
        default:
            break
        }
        let expectedEndBoundary: String
        switch notificationScrollRestoreState.replay {
        case .replaying(let value), .replayingAfterExplicitInput(let value):
            expectedEndBoundary = value
        default:
            return false
        }
        guard boundary == expectedEndBoundary else { return false }

        if let geometry = authoritativeGeometry ?? surfaceView.authoritativeScrollbarGeometry() {
            notificationScrollRestoreState.replay = .completed(geometry)
            configureWaitingRequestAfterReplay(using: geometry)
        } else {
            notificationScrollRestoreState.replay = .completedAwaitingGeometry
        }
        _ = restorePendingNotificationScrollPositionIfReady(
            authoritativeGeometry: authoritativeGeometry
        )
        return true
    }

    var hasPendingNotificationScrollRestore: Bool {
        notificationScrollRestoreState.pendingPosition != nil
    }

    func terminalSurfaceDidReceiveExplicitInput() {
        cancelPendingNotificationScrollRestoreForUserInput()
    }

    func restorePendingNotificationScrollPositionAfterScrollbarUpdate() {
        _ = restorePendingNotificationScrollPositionIfReady()
    }
}

@MainActor
extension GhosttyNSView {
    func authoritativeScrollbarGeometry() -> NotificationScrollRestoreGeometry? {
        var result = ghostty_surface_scrollbar_s()
        guard readAuthoritativeScrollbar(&result) else { return nil }
        return NotificationScrollRestoreGeometry(c: result)
    }

    func scrollToRow(
        _ row: Int,
        ifRowSpaceRevisionMatches rowSpaceRevision: UInt64
    ) -> NotificationScrollRestoreGeometry? {
        guard let row = UInt64(exactly: row) else { return nil }
        var result = ghostty_surface_scrollbar_s()
        guard scrollToRow(
            row,
            ifRowSpaceRevisionMatches: rowSpaceRevision,
            result: &result
        ) else { return nil }
        return NotificationScrollRestoreGeometry(c: result)
    }
}


// MARK: - Prompt scroll markers

/// One user-prompt boundary anchored to Ghostty's current absolute row space.
///
/// The marker captures the live-bottom viewport when the prompt-submit hook
/// arrives. Appended output leaves that row stable. If Ghostty later renumbers
/// bounded scrollback, the row-space revision changes and the marker expires
/// with the rows it referenced.
struct TerminalPromptScrollMarker: Equatable, Sendable {
    let topRow: UInt64
    let rowSpaceRevision: UInt64

    init?(geometry: NotificationScrollRestoreGeometry) {
        let scrollbar = geometry.scrollbar
        let visibleRows = min(scrollbar.total, scrollbar.len)
        guard visibleRows > 0 else { return nil }

        topRow = scrollbar.total - visibleRows
        rowSpaceRevision = geometry.rowSpaceRevision
    }

    /// Position in the scrollable track, where 0 is the oldest reachable
    /// viewport and 1 is the live bottom.
    func trackFraction(in geometry: NotificationScrollRestoreGeometry) -> CGFloat? {
        guard geometry.rowSpaceRevision == rowSpaceRevision else { return nil }

        let scrollbar = geometry.scrollbar
        let visibleRows = min(scrollbar.total, scrollbar.len)
        guard visibleRows > 0 else { return nil }

        let lastTopRow = scrollbar.total - visibleRows
        guard lastTopRow > 0, topRow <= lastTopRow else { return nil }
        return CGFloat(Double(topRow) / Double(lastTopRow))
    }
}

@MainActor
private final class TerminalPromptScrollMarkerOverlayView: NSView {
    weak var scroller: NSScroller?
    var onActivate: ((TerminalPromptScrollMarker) -> Void)?

    private var markers: [TerminalPromptScrollMarker] = []
    private var geometry: NotificationScrollRestoreGeometry?

    override var isOpaque: Bool { false }

    func update(
        markers: [TerminalPromptScrollMarker],
        geometry: NotificationScrollRestoreGeometry?
    ) {
        self.markers = markers
        self.geometry = geometry
        isHidden = markerEntries().isEmpty
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlAccentColor.setFill()
        for entry in markerEntries() where entry.rect.intersects(dirtyRect) {
            NSBezierPath(
                roundedRect: entry.rect,
                xRadius: entry.rect.height / 2,
                yRadius: entry.rect.height / 2
            ).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        marker(at: point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let marker = marker(at: point) else { return }
        onActivate?(marker)
    }

    private func marker(at point: NSPoint) -> TerminalPromptScrollMarker? {
        markerEntries()
            .filter { $0.hitRect.contains(point) }
            .min { lhs, rhs in
                abs(lhs.rect.midY - point.y) < abs(rhs.rect.midY - point.y)
            }?
            .marker
    }

    private func markerEntries() -> [
        (marker: TerminalPromptScrollMarker, rect: NSRect, hitRect: NSRect)
    ] {
        guard let geometry else { return [] }
        return markers.compactMap { marker in
            guard let rect = markerRect(for: marker, geometry: geometry) else { return nil }
            return (
                marker: marker,
                rect: rect,
                hitRect: rect.insetBy(dx: -2, dy: -4)
            )
        }
    }

    private func markerRect(
        for marker: TerminalPromptScrollMarker,
        geometry: NotificationScrollRestoreGeometry
    ) -> NSRect? {
        guard let fraction = marker.trackFraction(in: geometry) else { return nil }

        let slot = scroller?.rect(for: .knobSlot) ?? bounds
        guard slot.width > 0, slot.height > 0 else { return nil }

        let markerHeight: CGFloat = min(3, slot.height)
        let markerWidth: CGFloat = max(2, min(slot.width, 8))
        let centerY = slot.maxY - (fraction * slot.height)
        let originY = min(
            max(centerY - markerHeight / 2, slot.minY),
            slot.maxY - markerHeight
        )

        return NSRect(
            x: slot.midX - markerWidth / 2,
            y: originY,
            width: markerWidth,
            height: markerHeight
        )
    }
}

@MainActor
private final class TerminalPromptScrollMarkerController {
    private weak var hostedView: GhosttySurfaceScrollView?
    private let overlay = TerminalPromptScrollMarkerOverlayView(frame: .zero)
    private var markers: [TerminalPromptScrollMarker] = []
    private var observers: [NSObjectProtocol] = []

    init(hostedView: GhosttySurfaceScrollView) {
        self.hostedView = hostedView
        overlay.onActivate = { [weak self] marker in
            _ = self?.activate(marker)
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: hostedView.surfaceView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshFromRuntime()
            }
        })
        observers.append(center.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshFromRuntime()
            }
        })

        attachOverlayIfNeeded()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func recordPromptBoundary() {
        guard let hostedView,
              let geometry = hostedView.surfaceView.authoritativeScrollbarGeometry(),
              let marker = TerminalPromptScrollMarker(geometry: geometry) else { return }

        markers.removeAll { $0.rowSpaceRevision != geometry.rowSpaceRevision }
        markers.append(marker)
        refresh(using: geometry)
    }

    private func refreshFromRuntime() {
        attachOverlayIfNeeded()
        guard let hostedView,
              let geometry = hostedView.surfaceView.authoritativeScrollbarGeometry() else {
            overlay.update(markers: [], geometry: nil)
            return
        }
        refresh(using: geometry)
    }

    private func refresh(using geometry: NotificationScrollRestoreGeometry) {
        let scrollbar = geometry.scrollbar
        let visibleRows = min(scrollbar.total, scrollbar.len)
        let lastTopRow = scrollbar.total - visibleRows

        markers.removeAll {
            $0.rowSpaceRevision != geometry.rowSpaceRevision ||
            $0.topRow > lastTopRow
        }
        attachOverlayIfNeeded()
        overlay.update(markers: markers, geometry: geometry)
    }

    private func attachOverlayIfNeeded() {
        guard let hostedView,
              let terminalScrollView = hostedView.subviews.compactMap({ $0 as? NSScrollView }).first,
              let scroller = terminalScrollView.verticalScroller else { return }
        guard overlay.superview !== scroller else { return }

        overlay.removeFromSuperview()
        overlay.scroller = scroller
        overlay.frame = scroller.bounds
        overlay.autoresizingMask = [.width, .height]
        scroller.addSubview(overlay)
    }

    #if DEBUG
    var markerRowsForTesting: [UInt64] {
        markers.map(\.topRow)
    }

    func activateMarkerForTesting(at index: Int) -> Bool {
        guard markers.indices.contains(index) else { return false }
        return activate(markers[index])
    }
    #endif

    private func activate(_ marker: TerminalPromptScrollMarker) -> Bool {
        guard let hostedView,
              let geometry = hostedView.surfaceView.authoritativeScrollbarGeometry(),
              geometry.rowSpaceRevision == marker.rowSpaceRevision,
              let row = Int(exactly: marker.topRow) else { return false }

        let scrollbar = geometry.scrollbar
        let lastTopRow = scrollbar.total - min(scrollbar.total, scrollbar.len)
        guard marker.topRow <= lastTopRow else { return false }

        hostedView.clearPendingNotificationScrollRestore()
        let previousIntent = hostedView.prepareExplicitViewportRestore(
            isAtBottom: marker.topRow >= lastTopRow
        )
        guard hostedView.surfaceView.scrollToRow(
            row,
            ifRowSpaceRevisionMatches: marker.rowSpaceRevision
        ) != nil else {
            hostedView.rollbackExplicitViewportRestore(to: previousIntent)
            refresh(using: geometry)
            return false
        }
        return true
    }
}

@MainActor
private enum TerminalPromptScrollMarkerControllers {
    static let table =
        NSMapTable<GhosttySurfaceScrollView, TerminalPromptScrollMarkerController>
            .weakToStrongObjects()

    static func controller(
        for hostedView: GhosttySurfaceScrollView
    ) -> TerminalPromptScrollMarkerController {
        if let existing = table.object(forKey: hostedView) {
            return existing
        }
        let controller = TerminalPromptScrollMarkerController(hostedView: hostedView)
        table.setObject(controller, forKey: hostedView)
        return controller
    }
}

@MainActor
extension GhosttySurfaceScrollView {
    /// Records one prompt boundary using the terminal's authoritative row-space
    /// geometry. Prompt text remains in the existing workspace/session metadata;
    /// the scrollbar keeps only the row anchor needed for navigation.
    func recordPromptScrollMarker() {
        TerminalPromptScrollMarkerControllers
            .controller(for: self)
            .recordPromptBoundary()
    }

    #if DEBUG
    var promptScrollMarkerRowsForTesting: [UInt64] {
        TerminalPromptScrollMarkerControllers
            .controller(for: self)
            .markerRowsForTesting
    }

    func activatePromptScrollMarkerForTesting(at index: Int) -> Bool {
        TerminalPromptScrollMarkerControllers
            .controller(for: self)
            .activateMarkerForTesting(at: index)
    }
    #endif
}
