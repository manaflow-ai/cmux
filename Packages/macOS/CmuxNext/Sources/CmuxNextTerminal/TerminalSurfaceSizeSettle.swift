import AppKit
import CmuxNextWakeups

/// Gives a terminal surface its new size once the view's size is still
/// (perf I7). While a divider drag, a sidebar width animation or a layout
/// spring changes a pane's size every frame, `ghostty_surface_set_size` and
/// the grid report to the owner wait. The surface is host-sized
/// (`ghostty_surface_set_host_sized`): its drawable keeps the held size, so
/// no frame of the drag allocates or draws; the layer shows the last frame
/// from its top-left corner (`contentsGravity`), clipped by the host, with
/// the host's terminal background beside it, and new output still draws.
/// When the size stops the surface draws once, resizes its terminal and
/// reports its grid.
///
/// A live window resize is not deferred (`TerminalSurfaceView` applies it at
/// once): the owner's grid follows the window edge there, one in flight
/// (`ResizeCoordinator`), and each new grid needs the view's pixel size.
@MainActor final class TerminalSurfaceSizeSettle {
    static let shared = TerminalSurfaceSizeSettle()
    /// Frames a view's size stays unchanged before its surface takes it.
    static let stableFrames = 2

    private struct Pending {
        weak var view: TerminalSurfaceView?
        var size: CGSize
        var stable: Int
    }

    private var pending: [ObjectIdentifier: Pending] = [:]
    private lazy var frames = FrameClient(owner: "TerminalSurfaceSizeSettle", isAnimation: false, on: .app) { [weak self] _ in
        self?.tick() ?? false
    }

    /// `view`'s size changed: its surface takes the size once it is still.
    func submit(_ view: TerminalSurfaceView) {
        pending[ObjectIdentifier(view)] = Pending(view: view, size: view.bounds.size, stable: 0)
        frames.activate()
    }

    /// `view`'s surface took its size now (or the view went away).
    func cancel(_ view: TerminalSurfaceView) {
        pending[ObjectIdentifier(view)] = nil
    }

    private func tick() -> Bool {
        for (key, entry) in pending {
            guard let view = entry.view else {
                pending[key] = nil
                continue
            }
            if view.bounds.size != entry.size {
                pending[key] = Pending(view: view, size: view.bounds.size, stable: 0)
            } else if entry.stable + 1 >= Self.stableFrames {
                pending[key] = nil
                view.updateSurfaceSize()
            } else {
                pending[key]?.stable = entry.stable + 1
            }
        }
        return !pending.isEmpty
    }
}
