public import AppKit
import CmuxNextDesign

/// A sidebar point where a dragged tab cannot land, and why.
public struct SidebarTabDropRefusalHit: Hashable, Sendable {
    public var reason: SidebarTabDropRefusal
    /// The refused row, in screen coordinates.
    public var highlightFrame: CGRect
    /// The localized reason.
    public var text: String
}

/// Result of hit-testing an external tab drag.
public struct SidebarTabDropHit: Hashable, Sendable {
    public var drop: SidebarTabDrop
    /// Highlighted row, group header, gap, or "new" button, in screen coordinates.
    public var highlightFrame: CGRect
}

extension SidebarView {
    // MARK: External tab drag (driven by the App's TabDragSession)

    /// Hover time before a tab drag over a workspace row selects it.
    public var springLoadDelay: Duration {
        get { list.springLoadDelay }
        set { list.springLoadDelay = newValue }
    }

    /// Clock for the spring-load delay (inject a test clock).
    public var springLoadClock: any Clock<Duration> {
        get { list.springLoadClock }
        set { list.springLoadClock = newValue }
    }

    /// Call on every pointer move of an in-app tab drag. Opens a gap, lights
    /// a row or group, spring-loads rows, and auto-scrolls near the edges.
    /// Returns nil when the point is outside the sidebar or cannot accept the
    /// tab; the sidebar then clears its drop visuals.
    /// - Parameter sourceMachine: the tab's daemon; drops stay on that machine.
    public func tabDragUpdate(screenPoint: CGPoint, sourceMachine: MachineID?) -> SidebarTabDropHit? {
        guard let window, model.presentation != .hidden, !isHiddenOrHasHiddenAncestor else { return nil }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let local = convert(windowPoint, from: nil)
        guard bounds.contains(local) else {
            hideDropOutline()
            list.externalDragExited()
            setChromeRevealed(false)
            return nil
        }
        // Tracking areas do not fire during an app-driven drag; reveal the
        // "+" drop target explicitly.
        setChromeRevealed(true)
        if !newButton.isHidden, newButton.frame.insetBy(dx: -Metrics.space2, dy: -Metrics.space2).contains(local) {
            list.externalDragExited()
            let machine = sourceMachine ?? .local
            let index = model.section(.machine(machine))?.nodes.count ?? 0
            showDropOutline(convert(newButton.frame, to: nil), refused: false)
            return SidebarTabDropHit(
                drop: .newWorkspace(section: .machine(machine), group: nil, index: index),
                highlightFrame: window.convertToScreen(convert(newButton.frame, to: nil))
            )
        }
        guard let nearest = nearestListPoint(windowPoint),
              let (drop, rect) = list.externalDragMoved(windowPoint: nearest, sourceMachine: sourceMachine) else {
            return nil
        }
        showDropOutline(list.convert(rect, to: nil), refused: false)
        return SidebarTabDropHit(drop: drop, highlightFrame: window.convertToScreen(list.convert(rect, to: nil)))
    }

    /// Where `tabDragUpdate` found no drop inside the sidebar: why, the
    /// refused row (screen), and the localized reason. Draws the refused
    /// outline there (tab-dnd).
    public func tabDragRefusal(screenPoint: CGPoint, sourceMachine: MachineID?) -> SidebarTabDropRefusalHit? {
        guard let window, model.presentation != .hidden, !isHiddenOrHasHiddenAncestor else { return nil }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        guard bounds.contains(convert(windowPoint, from: nil)), let nearest = nearestListPoint(windowPoint),
              let (reason, rect) = list.externalDragRefusal(windowPoint: nearest, sourceMachine: sourceMachine) else {
            hideDropOutline()
            return nil
        }
        let inWindow = list.convert(rect, to: nil)
        // A refused row does not highlight (Lawrence 2026-10-05).
        hideDropOutline()
        return SidebarTabDropRefusalHit(reason: reason, highlightFrame: window.convertToScreen(inWindow), text: Strings.tabDropRefusal(reason))
    }

    /// The sidebar's own chrome (header, footer, the margins around the
    /// list) is no dead zone: it previews the list slot nearest to the
    /// pointer (tab-dnd, 2026-10-04). Nil when the list shows nothing.
    private func nearestListPoint(_ windowPoint: NSPoint) -> NSPoint? {
        let visible = list.visibleRect.insetBy(dx: 0.5, dy: 0.5)
        guard !visible.isEmpty else { return nil }
        let inList = list.convert(windowPoint, from: nil)
        return list.convert(CGPoint(x: min(max(inList.x, visible.minX), visible.maxX),
                                    y: min(max(inList.y, visible.minY), visible.maxY)), to: nil)
    }

    /// The drag left the sidebar or was cancelled (Escape).
    public func tabDragExited() {
        hideDropOutline()
        list.externalDragExited()
        setChromeRevealed(isPointerInside)
    }

    /// The drag was released. Returns the drop to commit, or nil. The App
    /// sends the daemon command and updates `model` (optimistically).
    @discardableResult
    public func tabDragEnded() -> SidebarTabDrop? {
        hideDropOutline()
        defer { setChromeRevealed(isPointerInside) }
        return list.externalDragEnded()
    }

    /// The hover owner's answer now (cx-3wu5): a drag that set the reveal
    /// itself hands it back to the pointer, so the owner and the reveal agree.
    private var isPointerInside: Bool {
        chromeHover?.refresh()
        return chromeHover?.isHovering ?? false
    }
}
