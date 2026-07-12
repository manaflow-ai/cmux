#if canImport(UIKit)
import CmuxMobileShell
import CmuxMobileTerminal
import SwiftUI
import UIKit

extension GhosttySurfaceRepresentable.Coordinator {
    /// Mount or unmount the SwiftUI compose field into the surface's composer
    /// band so the surface owns its position and grid reservation. Idempotent.
    @MainActor
    func setComposerMounted(_ mounted: Bool) {
        guard let store, let surfaceView else { return }
        guard mounted != composerMounted else {
            if !mounted {
                onComposerChromeHeightChange?(GhosttySurfaceView.persistentBottomToolbarHeight)
            }
            return
        }
        composerMounted = mounted
        composerMountGeneration &+= 1
        if mounted {
            let controller = composerController ?? makeComposerController(store: store)
            composerController = controller
            surfaceView.mountComposerView(controller.view)
            // The field opens at one line; report its initial height without
            // animation (the composer's open transition already animates), then
            // live grows/shrinks animate.
            reportComposerHeight(animated: false)
        } else {
            // Symmetric close: animate the band to 0 with the field STILL
            // mounted, on the keyboard curve, then unmount it in the completion.
            // Unmounting first left the band collapsing over empty space (a janky
            // close). Keep the surface reference for the deferred unmount.
            //
            // The completion is generation-guarded: UIKit runs animation
            // completions even when the animation is interrupted, so a
            // close-then-quick-reopen would otherwise unmount the freshly
            // remounted field and leave `composerMounted` true with no view.
            let generation = composerMountGeneration
            onComposerChromeHeightChange?(GhosttySurfaceView.persistentBottomToolbarHeight)
            surfaceView.setComposerBandHeight(0, animated: true) { [weak self] in
                guard let self,
                      self.composerMountGeneration == generation,
                      !self.composerMounted else { return }
                self.surfaceView?.mountComposerView(nil)
            }
        }
    }

    /// Re-measure the open composer after a non-text layout change (rotation /
    /// width change). A no-op when the composer is closed; `setComposerBandHeight`
    /// is idempotent on an unchanged height. Animated so a rotation reflow is smooth.
    @MainActor
    func remeasureComposerForLayoutChange() {
        guard composerMounted else { return }
        reportComposerHeight(animated: true)
    }

    /// Tear the hosting controller down on dismantle so a removed surface does not
    /// leave a detached SwiftUI host alive.
    @MainActor
    func tearDownComposer() {
        surfaceView?.mountComposerView(nil)
        composerController = nil
        composerMounted = false
        onComposerChromeHeightChange?(0)
    }

    /// Build the hosting controller for the compose field. The field asks for a
    /// re-measure (via ``reportComposerHeight(animated:)``) whenever its content
    /// changes; the coordinator measures the ideal height with `sizeThatFits` and
    /// sizes the surface band.
    @MainActor
    private func makeComposerController(store: CMUXMobileShellStore) -> UIHostingController<TerminalComposerView> {
        let view = TerminalComposerView(
            store: store,
            terminalID: surfaceID,
            submitRouter: composerSubmitRouter
        ) { [weak self] in
            // Content changed (a line added/removed, or cleared after send): live
            // grows/shrinks animate. `setComposerBandHeight` is idempotent on
            // unchanged heights, so a no-op change is harmless.
            self?.reportComposerHeight(animated: true)
        }
        let controller = UIHostingController(rootView: view)
        // The field is pinned edge-to-edge in the band, so the band frame (not an
        // intrinsic size) drives the hosting view's height; the measured ideal
        // height flows separately through `sizeThatFits`. Clear background so the
        // terminal/glass shows through.
        controller.view.backgroundColor = .clear
        return controller
    }

    /// Measure the hosted compose field's ideal height and size the surface band.
    /// `sizeThatFits` returns the height the content wants independent of the band's
    /// current (pinned) frame, so it is not circular: the band height is set FROM
    /// this measurement, and the measurement does not depend on the band height.
    /// The proposed width is the surface width and the proposed height is unbounded
    /// so a multi-line field measures its full desired height (capped to 14 lines by
    /// the field's own `lineLimit`).
    ///
    /// `requestHeightRemeasure` fires the instant the field's content changes — a
    /// `.onChange(of:)` action, or the post-send clear — which is BEFORE SwiftUI has
    /// committed that change into the hosted controller's view graph. Measuring a
    /// `UIHostingController` synchronously at that point captures the PRE-change
    /// (tall) ideal height, so after a send the band stays reserved tall and the
    /// empty field renders as a tall box that never collapses. It is worst for an
    /// image-only send: clearing the text fires no `.onChange(of: terminalInputText)`
    /// (it was already empty), so the stale measurement is never corrected by a
    /// follow-up. Flush the host's pending SwiftUI update into a concrete layout pass
    /// BEFORE calling `sizeThatFits` — mirroring the `setNeedsLayout()`/
    /// `layoutIfNeeded()` the GUI chat composer relies on to keep its hosted-field
    /// measurement current — so the measurement reflects the new (e.g. collapsed
    /// one-line) content. `sizeThatFits` re-proposes the surface width itself, so the
    /// flush only needs to apply the pending content change, not fix the width.
    @MainActor
    private func reportComposerHeight(animated: Bool) {
        guard let controller = composerController, let surfaceView else { return }
        // The hosting controller is mounted before any remeasure, so its view is
        // loaded; annotate to force-unwrap the `UIView!` rather than infer `UIView?`.
        let hostView: UIView = controller.view
        hostView.setNeedsLayout()
        hostView.layoutIfNeeded()
        let width = max(1, surfaceView.bounds.width)
        let fitting = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        surfaceView.setComposerBandHeight(fitting.height, animated: animated)
        onComposerChromeHeightChange?(
            fitting.height + GhosttySurfaceView.persistentBottomToolbarHeight
        )
    }
}
#endif
