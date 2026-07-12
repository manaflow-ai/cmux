#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

@MainActor
@Suite("Mobile recovery stress free drain", .serialized)
struct MobileRecoveryStressFreeDrainTests {
    private final class Delegate: NSObject, GhosttySurfaceViewDelegate {
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
            guard size.columns > 0, size.rows > 0 else { return }
            surfaceView.applyViewSize(cols: max(1, size.columns - 1), rows: max(1, size.rows - 1))
        }
    }

    @MainActor
    private struct Harness {
        let window: UIWindow
        let view: GhosttySurfaceView
        let delegate: Delegate

        func tearDown() {
            GhosttySurfaceView.RecoveryStressObservers.set(nil, for: view)
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }
    }

    @Test("forced recovery drains the old surface and accepts replacement output")
    func forcedRecoveryDrainsOldSurfaceAndAcceptsReplacementOutput() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }

        try await waitForMountedSurface(harness.view)
        try await pumpRecoveryTraffic(on: harness.view)

        let result = await exerciseRecovery(on: harness.view)
        #expect(result.generationAdvanced, "forced recovery should replace the render surface")
        #expect(result.outputApplied, "the replacement surface should acknowledge post-recovery output")
        #expect(result.containsSentinel, "the replacement surface should retain the post-recovery sentinel")
        #expect(result.freeDrained, "the old surface free should drain after forced render-pipeline recovery")
    }

    @Test("two hundred recoveries converge to the current container geometry")
    func twoHundredRecoveriesConvergeToCurrentContainerGeometry() async throws {
        let runtime = try GhosttyRuntime.shared()
        let coordinator = MobileRecoveryStressCoordinator(
            configuration: MobileRecoveryStressConfiguration(cycles: 200)
        )
        let view = GhosttySurfaceView(runtime: runtime, delegate: coordinator, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        coordinator.surfaceView = view

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
        defer {
            coordinator.stop()
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }

        try await waitForMountedSurface(view)
        coordinator.start()

        let converged = await waitUntil(timeout: .seconds(15)) {
            guard view.recoveryStressSnapshot().generation >= 200 else { return false }
            let geometry = view.debugGeometrySnapshotForTesting()
            let cellWidth = geometry.cellPixelSize.width / max(1, geometry.screenScale)
            let cellHeight = geometry.cellPixelSize.height / max(1, geometry.screenScale)
            return geometry.effectiveGrid == nil
                && abs(geometry.boundsSize.width - window.bounds.width) < 0.5
                && abs(geometry.boundsSize.height - window.bounds.height) < 0.5
                && geometry.renderRect.width > 0
                && geometry.renderRect.height > 0
                && geometry.viewportRect.width - geometry.renderRect.width <= cellWidth + 1
                && geometry.viewportRect.height - geometry.renderRect.height <= cellHeight + 1
        }
        #expect(
            converged,
            "PASS must wait until synthetic viewport pins are released and the renderer fills the current viewport"
        )
    }

    private func makeHarness() throws -> Harness {
        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return Harness(window: window, view: view, delegate: delegate)
    }

    private func waitForMountedSurface(_ view: GhosttySurfaceView) async throws {
        let mounted = await waitUntil(timeout: .seconds(5)) {
            view.window != nil && view.bounds.width > 100 && view.bounds.height > 100 && view.surface != nil
        }
        #expect(mounted, "test surface should mount before recovery stress starts")
    }

    private func pumpRecoveryTraffic(on view: GhosttySurfaceView) async throws {
        for cycle in 0..<6 {
            view.setFocus(cycle.isMultiple(of: 2))
            _ = await view.processOutputAndWait(Self.syntheticOutput(cycle: cycle))
            view.bounds = CGRect(
                origin: .zero,
                size: CGSize(width: 390 + CGFloat(cycle * 2), height: 820 - CGFloat(cycle * 3))
            )
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }

    private func exerciseRecovery(on view: GhosttySurfaceView) async -> (
        generationAdvanced: Bool,
        outputApplied: Bool,
        containsSentinel: Bool,
        freeDrained: Bool
    ) {
        let (stream, continuation) = AsyncStream<GhosttySurfaceView.RecoveryStressSnapshot>.makeStream()
        GhosttySurfaceView.RecoveryStressObservers.set({ snapshot in
            continuation.yield(snapshot)
        }, for: view)

        let before = view.recoveryStressSnapshot()
        let after = view.forceRecoveryForStress()
        let outputApplied = await view.processOutputAndWait(Self.postRecoverySentinel)
        let replacementText: String?
        if let replacementSurface = view.surface {
            replacementText = await view.copyableTextForCurrentSurface(surface: replacementSurface)
        } else {
            replacementText = nil
        }
        let containsSentinel = replacementText?.contains("RECOVERY-STRESS-TEST-RECOVERED") == true

        let freeDrained: Bool
        if after.pendingSurfaceFreeCount == 0 {
            freeDrained = true
        } else {
            freeDrained = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await snapshot in stream {
                        if snapshot.pendingSurfaceFreeCount == 0 {
                            return true
                        }
                    }
                    return false
                }
                group.addTask {
                    let clock = ContinuousClock()
                    do {
                        // Genuine test deadline for the teardown drain signal.
                        try await clock.sleep(for: .seconds(15))
                    } catch {
                        return false
                    }
                    return false
                }

                let result = await group.next() ?? false
                group.cancelAll()
                return result
            }
        }
        GhosttySurfaceView.RecoveryStressObservers.set(nil, for: view)
        return (
            generationAdvanced: after.generation != before.generation,
            outputApplied: outputApplied,
            containsSentinel: containsSentinel,
            freeDrained: freeDrained
        )
    }

    private func waitUntil(
        timeout: Duration,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if predicate() { return true }
            do {
                // Bounded simulator test wait; cancellation comes from the test task.
                try await clock.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
        return predicate()
    }

    private static func syntheticOutput(cycle: Int) -> Data {
        var text = "\u{1b}[?2004h\u{1b}]133;A\u{07}\u{1b}]0;free drain regression \(cycle)\u{07}"
        for line in 0..<80 {
            text += "\u{1b}[38;5;\((line + cycle) % 216)m"
            text += "free-drain-regression cycle=\(cycle) line=\(line) "
            text += "abcdefghijklmnopqrstuvwxyz 0123456789 wrapping payload "
            text += "\u{1b}[0m\r\n"
            if line % 8 == 0 {
                text += "\u{1b}]7;file://stress/free-drain/\(cycle)/\(line)\u{07}"
            }
        }
        text += "\u{1b}]133;B\u{07}\u{1b}[?2004l\r\n"
        return Data(text.utf8)
    }

    private static let postRecoverySentinel = Data(
        "\u{1b}[2J\u{1b}[HRECOVERY-STRESS-TEST-RECOVERED".utf8
    )
}
#endif
