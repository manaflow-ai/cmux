public import Foundation
public import CoreGraphics
public import CmuxCore
import Observation

/// Per-window render-state mirror for the tmux pane overlay: the published
/// `unreadRects`/`flashRect`/`flashStartedAt`/`flashReason` that
/// `AppTmuxWorkspacePaneOverlayTarget` reads back to rebuild the overlay root
/// view after each ``CmuxCore/TmuxWorkspacePaneOverlayRenderState`` update.
///
/// It owns the per-workspace flash-token bookkeeping (`currentWorkspaceId`,
/// `lastFlashTokenByWorkspaceId`) that decides when a new flash should restart
/// its animation start date versus reuse the running one. ``apply(_:now:)``
/// folds one render state into the mirror; ``clear()`` resets everything.
///
/// `@MainActor` because every caller is a MainActor overlay-update path. The
/// model holds no I/O and no back-reference to live workspace state; it is a
/// pure value mirror driven by immutable render-state snapshots, so the move
/// into this package is byte-faithful with the legacy `ObservableObject`
/// (callers read the same properties imperatively and rebuild the root view in
/// lock-step).
@MainActor
@Observable
public final class TmuxWorkspacePaneOverlayModel {
    /// The unread-indicator rects from the most recent render state.
    public private(set) var unreadRects: [CGRect] = []

    /// The optional flash rect from the most recent render state.
    public private(set) var flashRect: CGRect?

    /// The active pane border rect from the most recent render state.
    public private(set) var activePaneBorderRect: CGRect?

    /// The active pane border color from the most recent render state.
    public private(set) var activePaneBorderColorHex: String?

    /// When the currently-tracked flash began animating, if any.
    public private(set) var flashStartedAt: Date?

    /// The reason for the currently-tracked flash, if any.
    public private(set) var flashReason: WorkspaceAttentionFlashReason?

    @ObservationIgnored
    private var currentWorkspaceId: UUID?
    @ObservationIgnored
    private var lastFlashTokenByWorkspaceId: [UUID: UInt64] = [:]

    /// Creates an empty overlay model.
    public init() {}

    /// Folds one render state into the mirror, restarting the flash start date
    /// when a new flash token arrives with a flash rect and clearing it on a
    /// workspace switch with no new flash.
    public func apply(
        _ state: TmuxWorkspacePaneOverlayRenderState,
        now: () -> Date = Date.init
    ) {
        unreadRects = state.unreadRects
        flashRect = state.flashRect
        activePaneBorderRect = state.activePaneBorderRect
        activePaneBorderColorHex = state.activePaneBorderColorHex
        flashReason = state.flashReason

        let didChangeWorkspace = currentWorkspaceId != state.workspaceId
        let previousFlashToken = lastFlashTokenByWorkspaceId[state.workspaceId]
        let didChangeFlashToken = previousFlashToken.map { state.flashToken != $0 } ?? (state.flashToken > 0)
        if didChangeFlashToken,
           state.flashRect != nil {
            flashStartedAt = now()
        } else if didChangeWorkspace {
            flashStartedAt = nil
        }
        currentWorkspaceId = state.workspaceId
        if (previousFlashToken == nil && state.flashToken == 0) ||
            !didChangeFlashToken ||
            state.flashRect != nil {
            lastFlashTokenByWorkspaceId[state.workspaceId] = state.flashToken
        }
    }

    /// Resets every published property and the flash-token bookkeeping.
    public func clear() {
        unreadRects = []
        flashRect = nil
        activePaneBorderRect = nil
        activePaneBorderColorHex = nil
        flashStartedAt = nil
        flashReason = nil
        currentWorkspaceId = nil
        lastFlashTokenByWorkspaceId = [:]
    }
}
