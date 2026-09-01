internal import CMUXMobileCore
public import CmuxMobileShellModel
internal import Foundation

/// A renderer that can draw provisional echo-prediction cells over one mounted
/// terminal surface.
///
/// The intended conformer is the Ghostty surface mount owner (the surface
/// coordinator in `CmuxMobileShellUI`), which knows the surface view's cell
/// metrics and can position an overlay of underlined provisional glyphs above
/// the terminal. The engine's overlay contract: draw `overlay.cells` only when
/// `overlay.isVisible`, underline every cell (mosh's underline-until-confirmed),
/// and clear on any snapshot with empty cells. No conformer exists yet; local
/// echo prediction currently runs the full predict/confirm/back-off loop
/// headlessly behind the debug toggle.
@MainActor
public protocol MobileEchoPredictionOverlayPresenting: AnyObject {
    /// The prediction overlay for `surfaceID` changed; redraw it.
    func echoPredictionOverlayDidChange(
        _ overlay: MobileEchoPredictionOverlay,
        surfaceID: String
    )
}

/// Weak per-surface presenter slot so a mounted view never leaks through the
/// composite.
struct MobileEchoPredictionPresenterBox {
    weak var presenter: (any MobileEchoPredictionOverlayPresenting)?
}

/// Local echo prediction integration seam.
///
/// Wiring (all gated on ``MobileShellComposite/isEchoPredictionEnabled``):
///
/// - typed input funnels through `enqueueTerminalRawInputAwaitingDrain`, the
///   single ordered-input choke point, into ``recordEchoPredictionKeystrokes``;
/// - the Mac's `terminal.input` acknowledgment (`terminalSeq`) reaches
///   ``acknowledgeEchoPredictionInput`` from `handleTerminalInputResponse`,
///   giving predictions their contradiction floor;
/// - every delivered authoritative render-grid frame reaches
///   ``reconcileEchoPrediction(with:)`` from `recordTerminalRenderGridDelivery`,
///   which runs on both the live delivery path and the replay path;
/// - stream resets and focus changes call ``resetEchoPrediction`` /
///   ``resetAllEchoPrediction`` so no prediction survives a rebuilt surface.
///
/// Expiry (no-echo detection) is event-driven: it is evaluated on each
/// keystroke and each reconciled frame rather than on a timer, per the
/// no-sleep-based-timing rule; frames stream continuously while connected, so
/// an expiry is observed within one frame interval.
extension MobileShellComposite {
    /// Local debug toggle, default OFF, read once per process launch (matching
    /// `MobileLatencyTrace`). Production rollout would go through a PostHog
    /// `CmuxFeatureFlags` runtime flag; that is a later, deliberate decision
    /// and this UserDefaults key must not become the production control plane.
    public nonisolated static let echoPredictionDebugDefaultsKey = "cmux.debug.echo-prediction"

    nonisolated static let isEchoPredictionEnabled: Bool =
        UserDefaults.standard.bool(forKey: echoPredictionDebugDefaultsKey)

    /// Attaches the overlay renderer for one mounted surface.
    public func registerEchoPredictionOverlayPresenter(
        _ presenter: any MobileEchoPredictionOverlayPresenting,
        surfaceID: String
    ) {
        guard Self.isEchoPredictionEnabled else { return }
        echoPredictionPresentersBySurfaceID[surfaceID] =
            MobileEchoPredictionPresenterBox(presenter: presenter)
        if let engine = echoPredictionEnginesBySurfaceID[surfaceID] {
            presenter.echoPredictionOverlayDidChange(engine.overlay, surfaceID: surfaceID)
        }
    }

    /// Detaches the overlay renderer at mount teardown.
    public func unregisterEchoPredictionOverlayPresenter(surfaceID: String) {
        echoPredictionPresentersBySurfaceID.removeValue(forKey: surfaceID)
    }

    /// Feeds one ordered-input chunk to the surface's prediction engine.
    func recordEchoPredictionKeystrokes(_ text: String, surfaceID: String) {
        guard Self.isEchoPredictionEnabled else { return }
        var engine = echoPredictionEnginesBySurfaceID[surfaceID] ?? MobileEchoPredictionEngine()
        let outcome = engine.registerKeystrokes(text, at: echoPredictionNow())
        echoPredictionEnginesBySurfaceID[surfaceID] = engine
        if outcome.overlayChanged {
            publishEchoPredictionOverlay(engine.overlay, surfaceID: surfaceID)
        }
    }

    /// Records the Mac's input acknowledgment sequence for a surface.
    func acknowledgeEchoPredictionInput(untilSeq seq: UInt64, surfaceID: String) {
        guard Self.isEchoPredictionEnabled,
              var engine = echoPredictionEnginesBySurfaceID[surfaceID] else { return }
        engine.acknowledgeInput(untilSeq: seq)
        echoPredictionEnginesBySurfaceID[surfaceID] = engine
    }

    /// Reconciles a delivered authoritative render-grid frame. Also creates the
    /// engine on first contact so the grid baseline exists before the first
    /// keystroke.
    func reconcileEchoPrediction(with renderGrid: MobileTerminalRenderGridFrame) {
        guard Self.isEchoPredictionEnabled else { return }
        var engine = echoPredictionEnginesBySurfaceID[renderGrid.surfaceID]
            ?? MobileEchoPredictionEngine()
        let outcome = engine.reconcile(
            MobileEchoAuthoritativeUpdate(frame: renderGrid),
            at: echoPredictionNow()
        )
        echoPredictionEnginesBySurfaceID[renderGrid.surfaceID] = engine
        if outcome.overlayChanged {
            publishEchoPredictionOverlay(engine.overlay, surfaceID: renderGrid.surfaceID)
        }
    }

    /// Drops prediction state for a rebuilt or torn-down surface.
    func resetEchoPrediction(surfaceID: String, discardEngine: Bool = false) {
        guard Self.isEchoPredictionEnabled else { return }
        if discardEngine {
            guard echoPredictionEnginesBySurfaceID.removeValue(forKey: surfaceID) != nil else {
                return
            }
        } else {
            guard var engine = echoPredictionEnginesBySurfaceID[surfaceID] else { return }
            engine.invalidateForStreamReset()
            echoPredictionEnginesBySurfaceID[surfaceID] = engine
        }
        publishEchoPredictionOverlay(
            MobileEchoPredictionOverlay(displayState: .tentative, epoch: 0, cells: []),
            surfaceID: surfaceID
        )
    }

    /// Drops prediction state for every surface (selection/focus change).
    func resetAllEchoPrediction() {
        guard Self.isEchoPredictionEnabled else { return }
        for surfaceID in echoPredictionEnginesBySurfaceID.keys {
            resetEchoPrediction(surfaceID: surfaceID)
        }
    }

    private func publishEchoPredictionOverlay(
        _ overlay: MobileEchoPredictionOverlay,
        surfaceID: String
    ) {
        guard let box = echoPredictionPresentersBySurfaceID[surfaceID] else { return }
        guard let presenter = box.presenter else {
            echoPredictionPresentersBySurfaceID.removeValue(forKey: surfaceID)
            return
        }
        presenter.echoPredictionOverlayDidChange(overlay, surfaceID: surfaceID)
    }

    private func echoPredictionNow() -> TimeInterval {
        (runtime?.now() ?? Date()).timeIntervalSinceReferenceDate
    }
}
