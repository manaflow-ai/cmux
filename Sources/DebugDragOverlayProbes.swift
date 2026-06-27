#if DEBUG
import AppKit
import CmuxControlSocket
import Foundation

/// App-side probes for the live system drag pasteboard and the app's drag/drop
/// overlay hit-testing, backing the DEBUG-only v1 socket commands
/// `seed_drag_pasteboard_types`, `clear_drag_pasteboard`, `overlay_hit_gate`,
/// `overlay_drop_gate`, `portal_hit_gate`, `sidebar_overlay_gate`,
/// `terminal_drop_overlay_probe`, `drop_hit_test`, and `drag_hit_chain`.
///
/// The `ControlDebugContext` witnesses on ``TerminalController`` keep the
/// `v2MainSync` scope hop (which re-establishes the socket-command
/// focus-allowance stack the controller owns) and forward to these methods; the
/// bodies are the byte-faithful inner main-thread work. That work touches only
/// app-global AppKit state (the `.drag` ``NSPasteboard``, ``NSApp`` windows, and
/// the global file-drop overlay associated-object keyed by `fileDropOverlayKey`)
/// plus, for ``terminalDropOverlayProbe(panel:useDeferredPath:)``, a
/// caller-resolved ``TerminalPanel`` (the controller resolves it from its tab
/// graph and packages the `.tabManagerUnavailable`/`.noWorkspace`/`.noPanel`
/// outcomes, which need the controller's `tabManager`/`orderedPanels`).
///
/// The type holds no state because the drag pasteboard and overlay are
/// app-global, not per-controller; ``TerminalController`` owns one instance.
@MainActor
final class DebugDragOverlayProbes {
    /// Creates the stateless drag/drop-overlay probe collaborator.
    init() {}

    /// Declares the named pasteboard types on the system drag pasteboard, for
    /// the v1-only `seed_drag_pasteboard_types` command.
    func seedDragPasteboardTypes(arguments: String) -> String {
        let raw = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "ERROR: Usage: seed_drag_pasteboard_types <type[,type...]>"
        }

        let tokens = raw
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else {
            return "ERROR: Usage: seed_drag_pasteboard_types <type[,type...]>"
        }

        var types: [NSPasteboard.PasteboardType] = []
        for token in tokens {
            guard let mapped = NSPasteboard.PasteboardType.cmuxDebugDragType(from: token) else {
                return "ERROR: Unknown drag type '\(token)'"
            }
            if !types.contains(mapped) {
                types.append(mapped)
            }
        }

        _ = NSPasteboard(name: .drag).declareTypes(types, owner: nil)
        return "OK"
    }

    /// Clears the system drag pasteboard for the v1-only `clear_drag_pasteboard`
    /// command.
    func clearDragPasteboard() -> String {
        _ = NSPasteboard(name: .drag).clearContents()
        return "OK"
    }

    /// Evaluates the file-drop overlay hit-capture policy against the live drag
    /// pasteboard types for the v1-only `overlay_hit_gate` command.
    func overlayHitGate(eventToken: ControlDebugOverlayEventToken) -> Bool {
        let eventType = eventToken.nsEventType
        let pb = NSPasteboard(name: .drag)
        return DragOverlayRoutingPolicy.shouldCaptureFileDropOverlay(
            pasteboardTypes: pb.types,
            eventType: eventType
        )
    }

    /// Evaluates the file-drop destination overlay-capture policy against the
    /// live drag pasteboard types for the v1-only `overlay_drop_gate` command.
    func overlayDropGate(hasLocalDraggingSource: Bool) -> Bool {
        let pb = NSPasteboard(name: .drag)
        return DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
            pasteboardTypes: pb.types,
            hasLocalDraggingSource: hasLocalDraggingSource
        )
    }

    /// Evaluates the terminal-portal hit-pass-through policy against the live
    /// drag pasteboard types for the v1-only `portal_hit_gate` command.
    func portalHitGate(eventToken: ControlDebugOverlayEventToken) -> Bool {
        let eventType = eventToken.nsEventType
        let pb = NSPasteboard(name: .drag)
        return DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
            pasteboardTypes: pb.types,
            eventType: eventType
        )
    }

    /// Evaluates the sidebar external-overlay capture policy against the live
    /// drag pasteboard types for the v1-only `sidebar_overlay_gate` command.
    func sidebarOverlayGate(hasSidebarDragState: Bool) -> Bool {
        let pb = NSPasteboard(name: .drag)
        return DragOverlayRoutingPolicy.shouldCaptureSidebarExternalOverlay(
            hasSidebarDragState: hasSidebarDragState,
            pasteboardTypes: pb.types
        )
    }

    /// Probes the terminal drop-overlay animation on the caller-resolved
    /// `terminalPanel`'s hosted view and packages the `.probed` outcome, for the
    /// v1-only `terminal_drop_overlay_probe` command. The controller resolves the
    /// panel from its tab graph (and owns the `.tabManagerUnavailable`/
    /// `.noWorkspace`/`.noPanel` outcomes).
    func terminalDropOverlayProbe(
        panel terminalPanel: TerminalPanel,
        useDeferredPath: Bool
    ) -> ControlDebugTerminalDropOverlayProbeResolution {
        let probe = terminalPanel.hostedView.debugProbeDropOverlayAnimation(
            useDeferredPath: useDeferredPath
        )
        return .probed(
            before: probe.before,
            after: probe.after,
            boundsWidth: Double(probe.bounds.width),
            boundsHeight: Double(probe.bounds.height)
        )
    }

    /// Hit-tests the file-drop overlay's coordinate-to-terminal mapping.
    /// Takes normalised (0-1) x,y within the content area where (0,0) is the
    /// top-left corner and (1,1) is the bottom-right corner. Returns the
    /// surface UUID of the terminal under that point, or "none".
    func dropHitTest(nx: Double, ny: Double) -> String {
        var result = "ERROR: No window"
        guard let window = NSApp.mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { win in
                guard let raw = win.identifier?.rawValue else { return false }
                return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
            }),
              let contentView = window.contentView,
              let themeFrame = contentView.superview else { return result }

        // Convert normalized top-left coordinates into a window point.
        let pointInTheme = NSPoint(
            x: contentView.frame.minX + (contentView.bounds.width * nx),
            y: contentView.frame.maxY - (contentView.bounds.height * ny)
        )
        let windowPoint = themeFrame.convert(pointInTheme, to: nil)

        if let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? FileDropOverlayView,
           let terminal = overlay.terminalUnderPoint(windowPoint),
           let surfaceId = terminal.terminalSurface?.id {
            result = surfaceId.uuidString.uppercased()
            return result
        }

        result = "none"
        return result
    }

    /// Return the hit-test chain at normalized (0-1) coordinates in the main
    /// window's content area. Used by regression tests to detect root-level drag
    /// destinations shadowing pane-local Bonsplit drop targets.
    func dragHitChain(nx: Double, ny: Double) -> String {
        var result = "ERROR: No window"
        guard let window = NSApp.mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { win in
                guard let raw = win.identifier?.rawValue else { return false }
                return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
            }),
              let contentView = window.contentView,
              let themeFrame = contentView.superview else { return result }

        let pointInTheme = NSPoint(
            x: contentView.frame.minX + (contentView.bounds.width * nx),
            y: contentView.frame.maxY - (contentView.bounds.height * ny)
        )

        let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? NSView
        if let overlay { overlay.isHidden = true }
        defer { overlay?.isHidden = false }

        guard let hit = themeFrame.hitTest(pointInTheme) else {
            result = "none"
            return result
        }

        var chain: [String] = []
        var current: NSView? = hit
        var depth = 0
        while let view = current, depth < 8 {
            chain.append(view.cmuxDebugDragHitDescriptor)
            current = view.superview
            depth += 1
        }
        result = chain.joined(separator: "->")
        return result
    }
}
#endif
