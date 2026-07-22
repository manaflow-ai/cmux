import AppKit

@MainActor
final class SidebarResizerCursorReleaseScheduler {
    private let sleep: @MainActor (Duration) async throws -> Void
    private var pendingTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        sleep: @escaping @MainActor (Duration) async throws -> Void = { duration in
            // This is the intended cancellable UI delay; injection keeps tests deterministic.
            try await Task.sleep(for: duration)
        }
    ) {
        self.sleep = sleep
    }

    func cancelPendingRelease() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
    }

    func schedule(
        force: Bool,
        delay: Duration,
        release: @escaping @MainActor (Bool) -> Void
    ) {
        cancelPendingRelease()

        let scheduledGeneration = generation
        let sleep = self.sleep
        pendingTask = Task { @MainActor [weak self] in
            if delay > .zero {
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
            } else {
                await Task.yield()
                guard !Task.isCancelled else { return }
            }
            guard let self, generation == scheduledGeneration else { return }
            pendingTask = nil
            release(force)
        }
    }
}

@MainActor
struct SidebarResizerOcclusionResolver {
    var topmostMouseEventWindowNumber: (NSPoint) -> Int? = { screenPoint in
        let windowNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        return windowNumber > 0 ? windowNumber : nil
    }

    func dividerBandContains(
        point: NSPoint,
        contentBounds: NSRect,
        isLeftSidebarVisible: Bool,
        leftDividerX: CGFloat,
        isRightSidebarVisible: Bool,
        rightDividerX: CGFloat
    ) -> Bool {
        guard point.y >= contentBounds.minY, point.y <= contentBounds.maxY else { return false }
        if isLeftSidebarVisible,
           SidebarResizeInteraction.Edge.leading.hitRange(dividerX: leftDividerX).contains(point.x) {
            return true
        }
        return isRightSidebarVisible &&
            SidebarResizeInteraction.Edge.trailing.hitRange(dividerX: rightDividerX).contains(point.x)
    }

    func bandMayActivate(
        isDragging: Bool,
        isInDividerBand: Bool,
        screenPoint: NSPoint,
        observedWindowNumber: Int
    ) -> Bool {
        guard !isDragging else { return true }
        guard isInDividerBand else { return false }
        return topmostMouseEventWindowNumber(screenPoint) == observedWindowNumber
    }
}
