#if DEBUG
public import CMUXMobileCore
import Foundation

extension MobileShellComposite {
    /// Suspends the DEBUG theme fixture until its production output consumer is attached.
    ///
    /// The state is checked both before and while registering the continuation, so
    /// registration cannot be missed between observation and suspension.
    public func waitForThemeParityPreviewOutputSink(surfaceID: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !hasTerminalOutputSink(surfaceID: surfaceID) else { return true }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                guard !hasTerminalOutputSink(surfaceID: surfaceID) else {
                    continuation.resume(returning: true)
                    return
                }
                themeParityPreviewOutputSinkWaitersBySurfaceID[
                    surfaceID,
                    default: [:]
                ][waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveThemeParityPreviewOutputSinkWaiter(
                    surfaceID: surfaceID,
                    waiterID: waiterID,
                    value: false
                )
            }
        }
    }

    /// Injects a render-grid frame through the production surface delivery path.
    ///
    /// The theme-parity UI fixture uses this to verify mounted Ghostty surfaces,
    /// ordered config application, and canvas repainting through hybrid delivery.
    /// - Parameter frame: The Mac-style terminal frame to deliver.
    /// - Returns: `true` when the target surface has an attached output consumer.
    public func deliverThemeParityPreviewFrame(_ frame: MobileTerminalRenderGridFrame) -> Bool {
        guard hasTerminalOutputSink(surfaceID: frame.surfaceID) else { return false }
        terminalOutputTransport = .hybrid
        deliverAuthoritativeTerminalRenderGrid(frame, source: "event")
        return true
    }

    func resolveThemeParityPreviewOutputSinkWaiters(surfaceID: String) {
        guard let waiters = themeParityPreviewOutputSinkWaitersBySurfaceID.removeValue(
            forKey: surfaceID
        ) else {
            return
        }
        for continuation in waiters.values {
            continuation.resume(returning: true)
        }
    }

    private func resolveThemeParityPreviewOutputSinkWaiter(
        surfaceID: String,
        waiterID: UUID,
        value: Bool
    ) {
        guard let continuation = themeParityPreviewOutputSinkWaitersBySurfaceID[surfaceID]?
            .removeValue(forKey: waiterID) else {
            return
        }
        if themeParityPreviewOutputSinkWaitersBySurfaceID[surfaceID]?.isEmpty == true {
            themeParityPreviewOutputSinkWaitersBySurfaceID.removeValue(forKey: surfaceID)
        }
        continuation.resume(returning: value)
    }
}
#endif
