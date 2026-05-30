import Bonsplit
import CmuxTerminalAccess
import Foundation

/// Phase 0 forwarders for ``TerminalController`` — the surface-
/// provider seam ``AppSurfaceProvider`` calls into.
///
/// Read-only enumeration and handle resolution have real
/// implementations that mirror the existing v2 socket dispatch code
/// (cross-workspace walk via ``AppDelegate/mainWindowContexts``,
/// bonsplit-ordered terminal panels). The remaining write/text-read
/// methods are still stubs that throw ``TerminalAccessError/unknownSurface``;
/// later Task 0.24 sub-extracts will replace each in turn, alongside
/// its own red→green characterization test.
///
/// Keeping these forwarders in a dedicated `TerminalController+`
/// extension file (one type per file per project policy) means the
/// 20k-line `TerminalController.swift` isn't perturbed by Task 0.24 —
/// the extracts move the real bodies here from the existing dispatch
/// sites incrementally.
extension TerminalController {
    /// Enumerate every live cmux terminal surface as ``SurfaceInfo``
    /// snapshots (canonical sidebar order).
    ///
    /// Walks every live ``MainWindowContext`` → ``TabManager`` →
    /// ``Workspace`` → bonsplit-ordered terminal panels. Only
    /// ``TerminalPanel`` entries are emitted; browser/file-preview
    /// panels are not surfaces in the ``CmuxTerminalAccess`` model.
    ///
    /// Cols/rows are read from the live ``ghostty_surface_size`` when
    /// the runtime surface exists; pre-runtime panels report `(0, 0)`.
    /// ``SurfaceInfo/altScreen`` is `false` until ghostty exposes an
    /// `is_alt_screen` accessor (no such C API exists today); the same
    /// applies to ``SurfaceInfo/semanticAvailable``, which patch #1
    /// will flip on.
    @MainActor
    func v2EnumerateSurfaceInfos() -> [SurfaceInfo] {
        guard let app = AppDelegate.shared else { return [] }
        var infos: [SurfaceInfo] = []
        for context in app.mainWindowContexts.values {
            let manager = context.tabManager
            for workspace in manager.tabs {
                let workspaceRef = v2EnsureWorkspaceRef(uuid: workspace.id)
                let focusedSurfaceId = workspace.focusedPanelId
                // Mirror `orderedPanels(in:)` — use bonsplit's tab ordering
                // as the source of truth.
                var seen = Set<UUID>()
                let orderedTabIds = workspace.bonsplitController.allTabIds
                for tabId in orderedTabIds {
                    guard let panelId = workspace.panelIdFromSurfaceId(tabId),
                          let terminalPanel = workspace.terminalPanel(for: panelId)
                    else { continue }
                    seen.insert(panelId)
                    infos.append(
                        makeSurfaceInfo(
                            terminalPanel: terminalPanel,
                            workspace: workspace,
                            workspaceRef: workspaceRef,
                            focusedSurfaceId: focusedSurfaceId
                        )
                    )
                }
                // Defensive: include any orphaned terminal panels in a
                // stable order at the end (matches `orderedPanels(in:)`).
                let orphans = workspace.panels.values
                    .compactMap { $0 as? TerminalPanel }
                    .filter { !seen.contains($0.id) }
                    .sorted { $0.id.uuidString < $1.id.uuidString }
                for terminalPanel in orphans {
                    infos.append(
                        makeSurfaceInfo(
                            terminalPanel: terminalPanel,
                            workspace: workspace,
                            workspaceRef: workspaceRef,
                            focusedSurfaceId: focusedSurfaceId
                        )
                    )
                }
            }
        }
        return infos
    }

    /// Resolve a ``SurfaceHandle`` to its current ``SurfaceInfo``
    /// snapshot, or `nil` when the surface is no longer alive.
    ///
    /// Bridges the transport ``SurfaceHandle`` to the controller's
    /// existing handle registry via ``v2ResolveHandleRef(_:)``, then
    /// filters the cross-workspace enumeration for the matching UUID.
    @MainActor
    func v2Resolve(handle: SurfaceHandle) -> SurfaceInfo? {
        let uuid: UUID
        switch handle {
        case .uuid(let u):
            uuid = u
        case .ref:
            // The controller's handle registry takes the canonical string
            // form (e.g. "surface:1"); fall back to that path so the
            // ordinal aliases stay in sync with the rest of v2.
            guard let resolved = v2ResolveHandleRef(handle.stringValue) else {
                return nil
            }
            uuid = resolved
        }
        return v2EnumerateSurfaceInfos().first { $0.uuid == uuid }
    }

    /// Read rendered UTF-8 text from the given surface region.
    ///
    /// Phase 0 stub throws ``TerminalAccessError/unknownSurface``.
    /// Task 0.24.c will replace this with the real impl extracted from
    /// `readTerminalTextBase64` (the three-tag SCREEN+SURFACE+ACTIVE
    /// merge for `region == .screen`). The existing helper is `private`
    /// inside the 20k-line `TerminalController.swift`, so wiring it up
    /// requires either widening its visibility or duplicating the
    /// three-tag merge logic here. Per task 0.24 we are minimal-risk
    /// and don't touch `TerminalController.swift` from this extract, so
    /// the stub stays until the full extract can land alongside its
    /// characterization tests.
    func readSurfaceText(uuid: UUID, region: ScreenRegion) async throws -> String {
        _ = uuid
        _ = region
        throw TerminalAccessError.unknownSurface
    }

    /// Enqueue raw UTF-8 bytes onto the surface's PTY.
    ///
    /// Phase 0 stub throws ``TerminalAccessError/unknownSurface``.
    /// Task 0.24.d replaces this with the real impl extracted from
    /// `case "surface.send_text"`.
    func writeSurfaceText(uuid: UUID, bytes: Data) async throws {
        throw TerminalAccessError.unknownSurface
    }

    /// Encode and send a single ``KeyEvent`` via the existing
    /// `sendKeyToPanel` path.
    ///
    /// Phase 0 stub throws ``TerminalAccessError/unknownSurface``.
    /// Task 0.24.d replaces this with the real impl extracted from
    /// `case "surface.send_key"`.
    func writeSurfaceKey(uuid: UUID, event: KeyEvent) async throws {
        throw TerminalAccessError.unknownSurface
    }

    /// Dispatch a ``MouseEvent`` via the direct
    /// `ghostty_surface_mouse_*` C entrypoints (D16 — never through a
    /// synthesized `NSEvent`).
    ///
    /// Phase 0 stub throws ``TerminalAccessError/unknownSurface``.
    /// Task 0.24.e replaces this with the real impl.
    func writeSurfaceMouse(uuid: UUID, event: MouseEvent) async throws {
        throw TerminalAccessError.unknownSurface
    }

    /// Notify the surface that focus was gained or lost, without
    /// changing macOS app focus (socket-focus policy).
    ///
    /// Phase 0 stub throws ``TerminalAccessError/unknownSurface``.
    /// Task 0.24.e replaces this with the real impl that calls
    /// `ghostty_surface_set_focus` directly.
    func setSurfaceFocus(uuid: UUID, gained: Bool) async throws {
        throw TerminalAccessError.unknownSurface
    }

    /// Remaining bytes that may be enqueued onto the per-surface
    /// input queue before ``TerminalAccessError/payloadTooLarge`` fires.
    ///
    /// Phase 0 stub returns `0`. The byte counter
    /// (`pendingSocketInputBytes` on ``TerminalSurface``) is
    /// `private` and mutated on the main actor; reading it from this
    /// `nonisolated` protocol method would require either a new
    /// `@MainActor` accessor on ``TerminalSurface`` (touches
    /// `GhosttyTerminalView.swift`) or widening the field's visibility
    /// (touches `TerminalController.swift`'s sibling file). Neither
    /// fits the Phase 0 minimal-risk extract scope; the write paths
    /// through the service short-circuit on the unknown-surface error
    /// before reading this counter anyway. Task 0.24.e will introduce
    /// the accessor alongside its own characterization test.
    nonisolated func pendingInputCapacityRemaining(uuid: UUID) -> Int {
        _ = uuid
        return 0
    }

    // MARK: - Private helpers

    /// Snapshot the workspace ref string for `uuid` via the controller's
    /// handle registry. Allocates a new ordinal on the first sight of a
    /// workspace, matching what `v2SurfaceList` already does.
    @MainActor
    fileprivate func v2EnsureWorkspaceRef(uuid: UUID) -> String {
        guard let raw = v2Ref(kind: .workspace, uuid: uuid) as? String else {
            return uuid.uuidString
        }
        return raw
    }

    /// Build a ``SurfaceInfo`` snapshot for a single terminal panel.
    ///
    /// Cols/rows come from the live `ghostty_surface_size` when the
    /// runtime surface exists; otherwise they default to `0` (pre-
    /// runtime panels do not have a grid yet).
    @MainActor
    fileprivate func makeSurfaceInfo(
        terminalPanel: TerminalPanel,
        workspace: Workspace,
        workspaceRef: String,
        focusedSurfaceId: UUID?
    ) -> SurfaceInfo {
        let handle = SurfaceHandle.uuid(terminalPanel.id)
        let title = workspace.panelTitle(panelId: terminalPanel.id)
        var cols = 0
        var rows = 0
        if let surface = terminalPanel.surface.surface {
            let size = ghostty_surface_size(surface)
            cols = Int(size.columns)
            rows = Int(size.rows)
        }
        return SurfaceInfo(
            handle: handle,
            uuid: terminalPanel.id,
            workspaceRef: workspaceRef,
            title: title,
            cols: cols,
            rows: rows,
            // No `ghostty_surface_is_alt_screen` C API exists today;
            // patch #1 (cells/semantic) is expected to add one. Keep
            // the conservative default until then.
            altScreen: false,
            focused: terminalPanel.id == focusedSurfaceId,
            // Patch #1 flips this on for surfaces that expose semantic
            // prompt/output metadata. Phase 0 reports `false`.
            semanticAvailable: false
        )
    }
}
