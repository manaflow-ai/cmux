#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileTerminalKit
import Foundation
import UIKit

@MainActor
final class MobileBottomScrollStressCoordinator: NSObject, GhosttySurfaceViewDelegate {
    weak var surfaceView: GhosttySurfaceView?
    private var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }

    func start() {
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runScenario()
        }
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
        let initialTargetHeight = probeInt("targetViewportHeight", in: view.composerDockProbeValue) ?? Int(view.bounds.height)

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
            return target <= initialTargetHeight - 100
                && renderHeight <= target + 1
                && renderMinY <= 1
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
