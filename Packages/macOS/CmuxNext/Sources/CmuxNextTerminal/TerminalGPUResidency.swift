import Foundation
import GhosttyNextKit

/// Releases and restores the GPU memory of a hidden Ghostty surface: its IOSurface swap chain,
/// drawable pool and per-surface buffers, and its renderer thread
/// (`ghostty_surface_set_gpu_resident`, ghostty-next, p07-memory.md task 036). The terminal state and
/// the shared glyph atlas stay; a surface made resident again draws its next frame as before.
///
/// The App passes one to each ``TerminalSession`` (``GhosttyGPUResidency`` in the app, a recorder in
/// tests); nil keeps every surface resident.
@MainActor
public protocol TerminalGPUResidency: AnyObject {
    /// Makes `view`'s Ghostty surface resident (`true`) or lets its GPU memory go (`false`).
    func setResident(_ resident: Bool, of view: TerminalSurfaceView)
}

/// The libghostty switch, looked up by name so that a libghostty pinned before ghostty-next added it
/// still links. Chrome does the same for a hidden renderer: `LayerTreeHostImpl::SetVisible(false)`
/// (`cc/trees/layer_tree_host_impl.cc`) gives its tiles no GPU memory, and showing it rasters again
/// while the browser shows the saved frame.
@MainActor
public final class GhosttyGPUResidency: TerminalGPUResidency {
    private typealias SetResident = @convention(c) (ghostty_surface_t, Bool) -> Void
    private let setGPUResident: SetResident

    /// Nil when this libghostty has no `ghostty_surface_set_gpu_resident`: surfaces stay resident and
    /// the warm set keeps the size it has without the release (`SubsystemBudget`).
    public init?() {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ghostty_surface_set_gpu_resident") else { return nil }
        setGPUResident = unsafeBitCast(symbol, to: SetResident.self)
    }

    public func setResident(_ resident: Bool, of view: TerminalSurfaceView) {
        guard let surface = view.surface else { return }
        setGPUResident(surface, resident)
    }
}

/// When one surface view calls its ``TerminalGPUResidency``.
///
/// A paused surface outside the keep-alive band lets its GPU memory go after the pause reaches
/// Ghostty (Ghostty frees it once the frame in flight completes); its layer keeps the last presented
/// frame, volatile, which covers the gap. It is made resident again before the occlusion change that
/// draws its first frame on show. A surface in the keep-alive band, or one that draws, is never
/// released, so scrolling back to it costs no reallocation.
@MainActor
struct TerminalGPUResidencyGate {
    let seam: (any TerminalGPUResidency)?
    /// Whether the surface holds its GPU memory now (a new surface does; so does any without a seam).
    private(set) var resident = true

    init(seam: (any TerminalGPUResidency)?) {
        self.seam = seam
    }

    /// Before the occlusion change: a surface that keeps its GPU memory (`releases` false: it draws,
    /// or it is paused in the keep-alive band) is resident first. Returns the seam to call with `true`,
    /// or nil when nothing changes; the caller calls it after this access ends.
    mutating func acquire(releases: Bool) -> (any TerminalGPUResidency)? {
        guard !resident, !releases else { return nil }
        resident = true
        return seam
    }

    /// After the occlusion change: a paused surface away from the viewport (`releases`) lets its GPU
    /// memory go. Returns the seam to call with `false`, or nil when nothing changes.
    mutating func release(releases: Bool) -> (any TerminalGPUResidency)? {
        guard resident, releases, let seam else { return nil }
        resident = false
        return seam
    }
}
