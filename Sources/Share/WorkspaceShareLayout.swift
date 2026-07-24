import AppKit
import Bonsplit
import CmuxTerminal
import Foundation
import GhosttyKit

/// Pure geometry helpers for the share protocol's normalized [0,1] workspace
/// coordinates. Kept free of app types so unit tests can exercise the math
/// without launching the app.
enum WorkspaceShareLayoutMath {
    /// Normalizes a pane's pixel frame against the workspace container frame.
    /// Both rects share the same top-left-origin coordinate space (bonsplit's
    /// `LayoutSnapshot` pixel space). Output components are clamped to [0,1].
    static func normalizedRect(paneFrame: CGRect, container: CGRect) -> ShareRect {
        guard container.width > 0, container.height > 0 else {
            return ShareRect(x: 0, y: 0, w: 0, h: 0)
        }
        func clamp01(_ value: Double) -> Double { min(max(value, 0), 1) }
        let x = clamp01(Double((paneFrame.minX - container.minX) / container.width))
        let y = clamp01(Double((paneFrame.minY - container.minY) / container.height))
        let w = clamp01(Double(paneFrame.width / container.width))
        let h = clamp01(Double(paneFrame.height / container.height))
        return ShareRect(x: x, y: y, w: min(w, 1 - x), h: min(h, 1 - y))
    }

    /// Normalizes a point (same pixel space as the container) to [0,1], or nil
    /// when the point lies outside the container.
    static func normalizedPoint(_ point: CGPoint, container: CGRect) -> (x: Double, y: Double)? {
        guard container.width > 0, container.height > 0, container.contains(point) else { return nil }
        return (
            x: Double((point.x - container.minX) / container.width),
            y: Double((point.y - container.minY) / container.height)
        )
    }
}

/// Builds the wire `ShareWorkspace` from a live workspace's bonsplit tree.
@MainActor
enum WorkspaceShareLayoutBuilder {
    /// One pane per bonsplit pane, described by its selected tab's panel.
    /// `includeReplay` adds the capped terminal replay tail (snapshot frames
    /// only; live `layout` frames stay small).
    static func makeWorkspace(workspace: Workspace, includeReplay: Bool) -> ShareWorkspace {
        let snapshot = workspace.bonsplitController.layoutSnapshot()
        let container = CGRect(
            x: snapshot.containerFrame.x,
            y: snapshot.containerFrame.y,
            width: snapshot.containerFrame.width,
            height: snapshot.containerFrame.height
        )
        var panes: [ShareWorkspacePane] = []
        for geometry in snapshot.panes {
            guard let selectedTabIdString = geometry.selectedTabId,
                  let selectedTabUUID = UUID(uuidString: selectedTabIdString),
                  let panelId = workspace.panelIdFromSurfaceId(TabID(uuid: selectedTabUUID)),
                  let panel = workspace.panels[panelId] else {
                continue
            }
            let paneFrame = CGRect(
                x: geometry.frame.x,
                y: geometry.frame.y,
                width: geometry.frame.width,
                height: geometry.frame.height
            )
            var pane = ShareWorkspacePane(
                id: geometry.paneId,
                kind: shareKind(for: panel),
                title: workspace.panelTitle(panelId: panelId) ?? "",
                rect: WorkspaceShareLayoutMath.normalizedRect(paneFrame: paneFrame, container: container)
            )
            if let terminal = panel as? TerminalPanel {
                pane.surfaceId = terminal.id.uuidString
                if terminal.surface.hasLiveSurface, let ghosttySurface = terminal.surface.surface {
                    let size = ghostty_surface_size(ghosttySurface)
                    if size.columns > 0, size.rows > 0 {
                        pane.cols = Int(size.columns)
                        pane.rows = Int(size.rows)
                    }
                }
                if includeReplay,
                   let replay = MobileTerminalByteTee.shared.replayState(surfaceID: terminal.id) {
                    let capped = WorkspaceShareReplayCap.cappedReplayTail(replay.data)
                    pane.replaySeq = replay.seq - UInt64(capped.count)
                    pane.replay_b64 = capped.base64EncodedString()
                }
            }
            panes.append(pane)
        }
        return ShareWorkspace(
            title: workspace.title,
            size: ShareWorkspaceSize(width: Double(container.width), height: Double(container.height)),
            panes: panes
        )
    }

    private static func shareKind(for panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal: return "terminal"
        case .browser: return "browser"
        default: return "other"
        }
    }
}
