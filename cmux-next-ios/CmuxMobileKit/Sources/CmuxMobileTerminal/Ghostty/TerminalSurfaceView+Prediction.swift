#if os(iOS)
import CmuxMobileDesign
import Foundation
import UIKit

/// Predictive local echo on the surface (`TerminalPredictionOverlay`): every
/// write Ghostty encodes, every output batch (in `feed`) and every presented
/// frame reach the engine; the overlay follows the cursor Ghostty reports.
extension TerminalSurfaceView {
    /// One write Ghostty encoded, just before it leaves for the session.
    func predictionSent(_ data: Data) {
        guard predicts, surface != nil else { return }
        if predictionOverlay.prediction.sent(bytes: data, nowUs: TerminalPredictionOverlay.now()) { updatePrediction() }
    }

    /// A frame is on screen: a confirmed glyph held for it retires, and a
    /// drawn run follows the viewport the frame shows.
    func predictionPresented() {
        guard predicts else { return }
        let changed = predictionOverlay.prediction.presentedFrame(nowUs: TerminalPredictionOverlay.now())
        if changed || !predictionOverlay.isHidden { updatePrediction() }
    }

    /// Lays the run out for the cursor as Ghostty reports it now.
    func updatePrediction() {
        guard predicts, let surface else { return }
        attachPredictionOverlay()
        predictionOverlay.onExpire = { [weak self] in self?.updatePrediction() }
        predictionOverlay.update(surface: surface, fontSize: fontSize)
    }

    /// Settings → Terminal → Predictive echo changed: applies to open terminals at once.
    func applyPredictiveEcho() {
        let enabled = CmuxMobilePreferences.predictiveEcho()
        guard enabled != predicts else { return }
        predicts = enabled
        _ = predictionOverlay.prediction.setEnabled(enabled: enabled)
        if !enabled { predictionOverlay.clear() }
    }

    /// The overlay joins above Ghostty's layer, never before it: the screen
    /// reads Ghostty's frames from `layer.sublayers.first`.
    private func attachPredictionOverlay() {
        guard predictionOverlay.superview !== self, let first = layer.sublayers?.first, first !== predictionOverlay.layer else { return }
        addSubview(predictionOverlay)
    }
}
#endif
