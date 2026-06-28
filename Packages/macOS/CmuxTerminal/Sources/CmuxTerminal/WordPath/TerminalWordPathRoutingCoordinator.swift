import Foundation
public import CoreGraphics
public import CmuxTerminalCore

/// The cmd-click word-path / link routing decision orchestrator drained out of
/// the `GhosttyNSView` god type in `GhosttyTerminalView.swift` into `CmuxTerminal`.
///
/// It owns the precedence decision between the three cmd-click resolution
/// sources: the pointer-anchored visible-grid snapshot, Ghostty's QuickLook word,
/// and the viewport-offset visible-grid snapshot. The app-coupled reads (live
/// `ghostty_surface_t`, `TerminalController` text snapshots, cell/bounds geometry,
/// working-directory resolution) stay app-side behind ``TerminalWordPathHosting``;
/// this coordinator sequences those reads, runs the path heuristics through the
/// shared ``TerminalPathResolver`` in `CmuxTerminalCore`, applies the `#if DEBUG`
/// cmd-click overrides, and returns the winning ``WordPathResolution``.
///
/// The pointer-anchored snapshot is preferred over QuickLook and viewport offsets
/// because it is the only source tied directly to the click location; QuickLook
/// and viewport offsets can lag or target a sibling entry in multi-column `ls`
/// output. The hover-cursor side effects and the `PreferredEditorService` open
/// stay app-side; this type only resolves.
///
/// Isolation design: the legacy methods were plain instance methods on the
/// non-isolated `GhosttyNSView`, invoked only on the main thread by convention
/// (mouse-down, hover, and cmd-click-release event callbacks). This drain
/// preserves that exact non-isolated shape as a plain `final class` (not
/// `Sendable`, not `@MainActor`), mirroring the sibling
/// ``TerminalAppearanceCoordinator`` so the host keeps constructing and calling it
/// byte-identically with no `@MainActor` ripple onto its non-isolated callers. The
/// host is held weakly because the host (the `GhosttyNSView`) owns this
/// coordinator.
public final class TerminalWordPathRoutingCoordinator {
    /// The app-target seam for the app-coupled cmd-click resolution inputs.
    public weak var host: (any TerminalWordPathHosting)?

    /// Creates the coordinator bound to its app-target host seam.
    public init(host: (any TerminalWordPathHosting)? = nil) {
        self.host = host
    }

    /// Resolves the word under the cursor (or the given point) to an existing
    /// file-system path, consulting the pointer-anchored snapshot, Ghostty's
    /// QuickLook word, and the viewport-offset snapshot in precedence order.
    ///
    /// - Parameter requestedPoint: The pointer location to anchor the snapshot to,
    ///   or `nil` to use the host's tracked pointer position.
    /// - Returns: The winning resolution, or `nil` when no source resolves.
    public func resolveWordUnderCursorPath(at requestedPoint: CGPoint? = nil) -> WordPathResolution? {
        guard let host else { return nil }
        guard let cwd = host.wordPathWorkingDirectory() else { return nil }

        let pointSnapshotResolution = host.pointSnapshotWordPath(at: requestedPoint, cwd: cwd)

        if let snapshot = host.quicklookWordSnapshot() {
            var quicklookResolution: WordPathResolution?
            if let decodedWord = snapshot.decodedWord {
#if DEBUG
                let resolvedQuicklookWord = cmuxTerminalCmdClickQuicklookOverride(decodedWord)
#else
                let resolvedQuicklookWord = decodedWord
#endif
                if let resolvedPath = TerminalPathResolver().resolveQuicklookPath(resolvedQuicklookWord, cwd: cwd) {
                    quicklookResolution = WordPathResolution(
                        path: resolvedPath,
                        source: .quicklook,
                        rawToken: resolvedQuicklookWord
                    )
                }
            }

            var viewportResolution: WordPathResolution?
            if let rawViewportOffsetStart = snapshot.viewportOffsetStart {
#if DEBUG
                let viewportOffsetStart = cmuxTerminalCmdClickViewportOffsetDelta(rawViewportOffsetStart)
#else
                let viewportOffsetStart = rawViewportOffsetStart
#endif
                viewportResolution = host.viewportWordPath(viewportOffsetStart: viewportOffsetStart, cwd: cwd)
            }

            if let viewportResolution {
                // The pointer-anchored snapshot is the only source tied directly to the
                // actual click location. Prefer it over quicklook and viewport offsets,
                // which can lag or target a sibling entry in multi-column `ls` output.
                if let pointSnapshotResolution {
                    return pointSnapshotResolution
                }
                return viewportResolution
            }

            if let pointSnapshotResolution {
                return pointSnapshotResolution
            }

            if let quicklookResolution {
                return quicklookResolution
            }
        }

        return pointSnapshotResolution
    }

    /// Resolves the word under the cursor to an existing path string.
    ///
    /// - Parameter requestedPoint: The pointer location to anchor to, or `nil`.
    /// - Returns: The winning resolved path, or `nil`.
    public func resolveWordUnderCursorAsPath(at requestedPoint: CGPoint? = nil) -> String? {
        resolveWordUnderCursorPath(at: requestedPoint)?.path
    }

#if DEBUG
    /// UI-test override for the decoded QuickLook word. Returns the environment
    /// override when set, otherwise the decoded word unchanged.
    private func cmuxTerminalCmdClickQuicklookOverride(_ decodedWord: String) -> String {
        let env = ProcessInfo.processInfo.environment
        guard let override = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_QUICKLOOK_OVERRIDE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty else {
            return decodedWord
        }
        return override
    }

    /// UI-test override for the viewport offset start. Applies the configured
    /// delta (clamped at zero) when set, otherwise the offset unchanged.
    private func cmuxTerminalCmdClickViewportOffsetDelta(_ viewportOffsetStart: Int) -> Int {
        let env = ProcessInfo.processInfo.environment
        guard let delta = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_VIEWPORT_OFFSET_DELTA"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let parsedDelta = Int(delta) else {
            return viewportOffsetStart
        }
        return max(0, viewportOffsetStart + parsedDelta)
    }
#endif
}
