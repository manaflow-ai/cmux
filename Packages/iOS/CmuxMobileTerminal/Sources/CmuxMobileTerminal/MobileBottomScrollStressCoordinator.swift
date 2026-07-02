#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileTerminalKit
import Foundation
import UIKit

@MainActor
final class MobileBottomScrollStressCoordinator: NSObject, GhosttySurfaceViewDelegate {
    weak var surfaceView: GhosttySurfaceView?
    private let scenario: MobileBottomScrollStressScenario
    private var task: Task<Void, Never>?

    init(scenario: MobileBottomScrollStressScenario = .composerShrink) {
        self.scenario = scenario
        super.init()
    }

    deinit {
        task?.cancel()
    }

    func start() {
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            switch self.scenario {
            case .composerShrink:
                await self.runScenario()
            case .fullReplayOffset:
                await self.runFullReplayOffsetScenario()
            }
        }
    }

    /// Repro for the "authoritative rebuild snaps the viewport to bottom" bug:
    /// seed scrollback, scroll the local mirror up into it, then apply a full
    /// `ESC c` snapshot the way an authoritative render-grid replay does. The
    /// phone-owned scroll position must survive the rebuild; ending phase is
    /// `done` when the offset is preserved and `regressed` when the rebuild
    /// moved the viewport.
    private func runFullReplayOffsetScenario() async {
        guard let view = surfaceView else { return }
        view.setBottomScrollStressPhase("mount")
        guard await waitForMountedSurface(view) else { return }

        view.setBottomScrollStressPhase("seed")
        _ = await view.processOutputAndWait(Data(Self.fullReplaySeedText(terminated: true).utf8))

        view.setBottomScrollStressPhase("bottom")
        view.scrollToBottomForBottomScrollStress()
        guard await waitUntil(timeoutNanoseconds: 2_000_000_000, {
            view.isBottomScrollStressAtBottom
        }) else {
            view.setBottomScrollStressPhase("timeout")
            return
        }

        view.setBottomScrollStressPhase("scrollback")
        view.applyLocalScrollbackScroll(lines: 60, col: 0, row: 0)
        guard await waitUntil(timeoutNanoseconds: 2_000_000_000, {
            view.scrollbackOffsetFromBottom >= 40
        }) else {
            view.setBottomScrollStressPhase("timeout")
            return
        }
        let preOffset = view.scrollbackOffsetFromBottom
        let scrollbarUpdatesBeforeReplay = view.scrollbarUpdateCount

        view.setBottomScrollStressPhase("replay")
        var replay = "\u{1B}c"
        replay += Self.fullReplaySeedText(terminated: false)
        _ = await view.processFullReplacementOutputAndWait(Data(replay.utf8))

        // The cached scrollbar still reports the pre-replay geometry until the
        // rebuilt terminal renders, so judging the offset immediately would
        // trivially pass. Require at least one post-replay scrollbar callback
        // before trusting the reading.
        guard await waitUntil(timeoutNanoseconds: 4_000_000_000, {
            view.scrollbarUpdateCount > scrollbarUpdatesBeforeReplay
        }) else {
            view.setBottomScrollStressPhase("timeout")
            return
        }
        let preserved = await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            let offset = view.scrollbackOffsetFromBottom
            return view.scrollbarUpdateCount > scrollbarUpdatesBeforeReplay
                && offset > 0
                && abs(offset - preOffset) <= 5
        }
        view.setBottomScrollStressPhase(preserved ? "done" : "regressed")
    }

    private static func fullReplaySeedText(terminated: Bool) -> String {
        var text = ""
        for i in 1...260 {
            text += String(format: "full-replay-repro line %03d", i)
            if i < 260 || terminated {
                text += "\r\n"
            }
        }
        return text
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {
        guard size.columns > 0, size.rows > 0 else { return }
        surfaceView.applyViewSize(cols: size.columns, rows: size.rows)
    }

    private func runScenario() async {
        guard let view = surfaceView else { return }
        view.setBottomScrollStressPhase("mount")
        guard await waitForMountedSurface(view) else { return }

        view.setBottomScrollStressPhase("seed")
        var text = ""
        for i in 1...260 {
            text += String(format: "bottom-scroll-repro line %03d\r\n", i)
        }
        _ = await view.processOutputAndWait(Data(text.utf8))

        view.setBottomScrollStressPhase("bottom")
        view.scrollToBottomForBottomScrollStress()
        _ = await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            view.isBottomScrollStressAtBottom
        }
        guard let initialTargetHeight = probeInt("targetViewportHeight", in: view.composerDockProbeValue) else {
            view.setBottomScrollStressPhase("timeout")
            return
        }

        let composer = UIView()
        composer.backgroundColor = .clear
        view.mountComposerView(composer)
        view.setComposerActive(true)

        view.setBottomScrollStressPhase("shrink")
        view.setComposerBandHeight(300, animated: false)
        view.debugSetKeyboardHeightForLayoutPreview(300)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        guard await waitUntil(timeoutNanoseconds: 2_000_000_000, {
            let probe = view.composerDockProbeValue
            if probe.contains("staleViewportObserved=1") { return true }
            guard let target = self.probeInt("targetViewportHeight", in: probe),
                  let renderHeight = self.probeInt("renderHeight", in: probe),
                  let renderMinY = self.probeInt("renderMinY", in: probe),
                  let scrollAtBottom = self.probeInt("scrollAtBottom", in: probe) else {
                return false
            }
            let renderBottom = renderMinY + renderHeight
            return target <= initialTargetHeight - 100
                && renderHeight <= target + 1
                && abs(renderBottom - target) <= 1
                && scrollAtBottom == 1
        }) else {
            view.setBottomScrollStressPhase("timeout")
            return
        }
        view.setBottomScrollStressPhase("done")
    }

    private func waitForMountedSurface(_ view: GhosttySurfaceView) async -> Bool {
        await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            view.window != nil && view.bounds.width > 100 && view.bounds.height > 100 && view.surface != nil
        }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64,
        _ predicate: @MainActor @escaping () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .nanoseconds(Int(timeoutNanoseconds))
        while clock.now < deadline {
            if Task.isCancelled { return false }
            if predicate() { return true }
            try? await clock.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private func probeInt(_ key: String, in probe: String) -> Int? {
        for field in probe.split(separator: ";") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, String(parts[0]) == key else { continue }
            return Int(parts[1])
        }
        return nil
    }
}
#endif
