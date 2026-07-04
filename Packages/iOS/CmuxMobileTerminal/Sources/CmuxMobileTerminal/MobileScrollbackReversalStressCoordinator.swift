#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import Foundation
import UIKit

@MainActor
final class MobileScrollbackReversalStressCoordinator: NSObject, GhosttySurfaceViewDelegate {
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

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
        guard size.columns > 0, size.rows > 0 else { return }
        surfaceView.applyViewSize(cols: size.columns, rows: size.rows)
    }

    private func runScenario() async {
        guard let view = surfaceView else { return }
        view.setScrollbackReversalStressFailure("none")
        view.setScrollbackReversalStressPhase("mount")
        guard await waitForMountedSurface(view) else { return fail(view, "mount-timeout") }

        view.setScrollbackReversalStressPhase("seed")
        var text = ""
        for i in 1...900 {
            text += String(format: "scrollback-reversal-row %04d\r\n", i)
        }
        guard await view.processOutputAndWait(Data(text.utf8)) else { return fail(view, "seed-output") }

        view.setScrollbackReversalStressPhase("bottom")
        view.scrollToBottomForScrollbackReversalStress()
        guard await waitUntil(timeoutNanoseconds: 2_000_000_000, { view.isScrollbackReversalStressAtBottom }) else {
            return fail(view, "bottom-timeout")
        }

        guard let upSign = await calibratedUpScrollSign(for: view) else {
            return fail(view, "direction-timeout")
        }
        view.scrollToBottomForScrollbackReversalStress()
        _ = await waitUntil(timeoutNanoseconds: 1_000_000_000, { view.isScrollbackReversalStressAtBottom })

        let row = max(1, view.currentGridSize.rows / 2)
        let col = max(1, view.currentGridSize.columns / 2)
        let magnitudes: [Double] = [10, 31, 7, 44, 18, 53, 5, 27]
        view.setScrollbackReversalStressPhase("stress")
        for cycle in 0..<72 {
            let primary = magnitudes[cycle % magnitudes.count]
            let secondary = magnitudes[(cycle + 3) % magnitudes.count]
            view.applyLocalScrollbackScroll(lines: upSign * primary, col: col, row: row)
            view.applyLocalScrollbackScroll(lines: -upSign * secondary, col: col, row: row)
            if cycle.isMultiple(of: 3) {
                view.applyLocalScrollbackScroll(lines: upSign * (secondary / 2), col: col, row: row)
            }
            if cycle.isMultiple(of: 6) {
                await pause(milliseconds: 12)
                if let failure = await visibleRowSequenceFailure(in: view) {
                    return fail(view, failure)
                }
            }
        }

        if let failure = await waitForVisibleRowsToSettle(in: view, timeoutNanoseconds: 2_000_000_000) {
            return fail(view, failure)
        }
        view.setScrollbackReversalStressPhase("done")
    }

    private func calibratedUpScrollSign(for view: GhosttySurfaceView) async -> Double? {
        guard let bottomOffset = view.scrollbackReversalStressOffset else { return nil }
        for sign in [1.0, -1.0] {
            view.applyLocalScrollbackScroll(lines: sign * 18, col: 1, row: max(1, view.currentGridSize.rows / 2))
            if await waitUntil(timeoutNanoseconds: 500_000_000, {
                guard let offset = view.scrollbackReversalStressOffset else { return false }
                return offset < bottomOffset
            }) {
                return sign
            }
        }
        return nil
    }

    private func waitForVisibleRowsToSettle(
        in view: GhosttySurfaceView,
        timeoutNanoseconds: UInt64
    ) async -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now + .nanoseconds(Int(timeoutNanoseconds))
        var lastFailure = "settle-timeout"
        while clock.now < deadline {
            if Task.isCancelled { return "cancelled" }
            if let failure = await visibleRowSequenceFailure(in: view) {
                lastFailure = failure
                await pause(milliseconds: 20)
                continue
            }
            return nil
        }
        return lastFailure
    }

    private func visibleRowSequenceFailure(in view: GhosttySurfaceView) async -> String? {
        let text = await view.scrollbackReversalViewportText() ?? ""
        let ids = visibleRowIDs(in: text)
        guard ids.count >= 4 else {
            return "visible-row-count-\(ids.count)"
        }
        for pair in zip(ids, ids.dropFirst()) {
            if pair.1 != pair.0 + 1 {
                return "row-jump-\(pair.0)-\(pair.1)"
            }
        }
        return nil
    }

    private func visibleRowIDs(in text: String) -> [Int] {
        let prefix = "scrollback-reversal-row "
        return text.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix(prefix) else { return nil }
            let suffix = line.dropFirst(prefix.count)
            let digits = suffix.prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            return Int(digits)
        }
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
            await pause(milliseconds: 20)
        }
        return predicate()
    }

    private func pause(milliseconds: Int) async {
        try? await ContinuousClock().sleep(for: .milliseconds(milliseconds))
    }

    private func fail(_ view: GhosttySurfaceView, _ failure: String) {
        view.setScrollbackReversalStressFailure(failure)
        view.setScrollbackReversalStressPhase("failed")
    }
}
#endif
