public import CmuxMobileShellModel
public import Foundation

/// A host that is not a paired Mac but contributes workspaces and serves
/// terminals through the same store paths a paired Mac's data flows through.
///
/// This is the seam a cmux Cloud machine reaches the phone's workspace
/// experience by. The store owns no knowledge of the backend: it asks the
/// registered sources which surfaces they own, and hands those surfaces'
/// input, viewport reports and replay requests back to the owner instead of
/// the Mac RPC pipeline. Everything above the store — the workspace list,
/// the detail chrome, the terminal surface, the composer — reads only
/// ``MobileWorkspacePreview`` values and a surface id, so it works unchanged.
///
/// Demonstration content uses a dedicated in-store path rather than this
/// protocol because its engine is local to the store; the fork points are the
/// same ones, checked in the same order.
@MainActor
public protocol MobileExternalHostSource: AnyObject {
    /// Whether this source serves the given terminal surface.
    ///
    /// Answered from a stable identifier namespace rather than live session
    /// state, so the fences hold while a link is down.
    func externalHostOwnsSurface(_ surfaceID: String) -> Bool

    /// Delivers typed input for an owned surface.
    func externalHostSendInput(_ text: String, surfaceID: String)

    /// Reports the phone's grid for an owned surface, so the host can resize
    /// its pseudo-terminal to match.
    func externalHostReportViewport(surfaceID: String, columns: Int, rows: Int)

    /// Asks the host to repaint an owned surface from its current full screen
    /// state, on mount and after a view reset.
    func externalHostRequestReplay(surfaceID: String)
}

@MainActor
extension MobileShellComposite {
    // MARK: Registration

    /// Registers a non-Mac host source. Registering the same instance twice
    /// is a no-op.
    public func registerExternalHostSource(_ source: any MobileExternalHostSource) {
        externalHostSources[ObjectIdentifier(source)] = source
    }

    /// Unregisters a source and drops every workspace entry it contributed,
    /// so a signed-out or torn-down backend leaves no rows behind.
    public func unregisterExternalHostSource(_ source: any MobileExternalHostSource) {
        externalHostSources.removeValue(forKey: ObjectIdentifier(source))
    }

    // MARK: Workspace contribution

    /// Publishes one external host's workspaces into the same per-host map a
    /// paired Mac's snapshot lands in, so the aggregated list, its groups and
    /// every detail surface derive over it unchanged.
    ///
    /// Writing an equal value is skipped: the map's observer recomputes the
    /// whole derived list, which a poll that returns identical rows would
    /// otherwise run on every tick.
    public func applyExternalHostWorkspaceState(_ state: MacWorkspaceState) {
        let key = MacPairingKey(
            macDeviceID: state.macDeviceID,
            instanceTag: state.instanceTag
        )
        guard workspacesByMac[key] != state else { return }
        workspacesByMac[key] = state
    }

    /// Removes one external host's contribution.
    public func removeExternalHostWorkspaceState(
        macDeviceID: String,
        instanceTag: String? = nil
    ) {
        let key = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
        workspacesByMac.removeValue(forKey: key)
    }

    // MARK: Terminal output

    /// Delivers a host's terminal bytes through the same per-surface stream a
    /// Mac's output rides, so the mounted emulator, its scrollback and its
    /// viewport accounting behave identically.
    @discardableResult
    public func deliverExternalHostTerminalBytes(
        _ bytes: Data,
        surfaceID: String
    ) -> Bool {
        guard externalHostOwnsSurface(surfaceID) else { return false }
        return deliverTerminalBytes(bytes, surfaceID: surfaceID)
    }

    /// Delivers a host's full-screen replay, erasing screen and scrollback
    /// first so a remount repaints from blank instead of appending a second
    /// copy of the transcript.
    @discardableResult
    public func deliverExternalHostTerminalReplay(
        _ bytes: Data,
        surfaceID: String
    ) -> Bool {
        guard externalHostOwnsSurface(surfaceID) else { return false }
        var payload = Data("\u{1B}[2J\u{1B}[3J\u{1B}[H".utf8)
        payload.append(bytes)
        return deliverTerminalBytes(payload, surfaceID: surfaceID, bypassReplayBarrier: true)
    }

    // MARK: Fences

    /// Whether any registered source serves this surface.
    func externalHostOwnsSurface(_ surfaceID: String) -> Bool {
        externalHostSource(owningSurface: surfaceID) != nil
    }

    /// The source serving this surface, when one does.
    func externalHostSource(owningSurface surfaceID: String) -> (any MobileExternalHostSource)? {
        guard !surfaceID.isEmpty, !externalHostSources.isEmpty else { return nil }
        for source in externalHostSources.values
        where source.externalHostOwnsSurface(surfaceID) {
            return source
        }
        return nil
    }

    /// Routes typed input to the owning source. Returns `false` for surfaces
    /// no source owns, so callers fall through to the Mac input pipeline.
    /// An owned surface is ALWAYS handled and never forwarded to a Mac: no
    /// Mac knows these identifiers.
    @discardableResult
    func handleExternalHostTerminalInput(_ text: String, surfaceID: String) -> Bool {
        guard let source = externalHostSource(owningSurface: surfaceID) else { return false }
        source.externalHostSendInput(text, surfaceID: surfaceID)
        return true
    }

    /// Routes a replay request to the owning source. Returns `false` when no
    /// source owns the surface.
    @discardableResult
    func handleExternalHostReplayRequest(surfaceID: String) -> Bool {
        guard let source = externalHostSource(owningSurface: surfaceID) else { return false }
        source.externalHostRequestReplay(surfaceID: surfaceID)
        return true
    }

    /// Routes a viewport report to the owning source. Returns `false` when no
    /// source owns the surface.
    @discardableResult
    func handleExternalHostViewportReport(
        surfaceID: String,
        columns: Int,
        rows: Int
    ) -> Bool {
        guard let source = externalHostSource(owningSurface: surfaceID) else { return false }
        source.externalHostReportViewport(
            surfaceID: surfaceID,
            columns: columns,
            rows: rows
        )
        return true
    }
}
