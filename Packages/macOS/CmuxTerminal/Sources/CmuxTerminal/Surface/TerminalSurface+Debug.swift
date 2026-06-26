public import Foundation
public import GhosttyKit
public import CmuxTerminalCore

// MARK: - Debug/CLI metadata accessors and DEBUG-only test helpers

extension TerminalSurface {
    func withDebugMetadataLock<T>(_ body: () -> T) -> T {
        debugMetadataLock.lock()
        defer { debugMetadataLock.unlock() }
        return body()
    }

    /// When this surface model was constructed.
    public func debugCreatedAt() -> Date {
        withDebugMetadataLock { createdAt }
    }

    /// When the current runtime surface was created, if it exists.
    public func debugRuntimeSurfaceCreatedAt() -> Date? {
        withDebugMetadataLock { runtimeSurfaceCreatedAt }
    }

    /// The first recorded teardown request, if any.
    public func debugTeardownRequest() -> (requestedAt: Date?, reason: String?) {
        withDebugMetadataLock { (teardownRequestedAt, teardownRequestReason) }
    }

    /// The last workspace id the surface belonged to.
    public func debugLastKnownWorkspaceId() -> UUID {
        tabId
    }

    /// A human-readable label for the surface launch context.
    public func debugSurfaceContextLabel() -> String {
        GhosttySurfaceRuntimeProbe.contextName(surfaceContext)
    }

    /// The active portal-host lease, decomposed for debug output.
    public func debugPortalHostLease() -> (hostId: String?, paneId: UUID?, inWindow: Bool?, area: CGFloat?) {
        guard let activePortalHostLease else {
            return (nil, nil, nil, nil)
        }
        return (
            hostId: String(describing: activePortalHostLease.hostId),
            paneId: activePortalHostLease.paneId,
            inWindow: activePortalHostLease.inWindow,
            area: activePortalHostLease.area
        )
    }

#if DEBUG
    static let surfaceLogPath = "/tmp/cmux-ghostty-surface.log"
    static let sizeLogPath = "/tmp/cmux-ghostty-size.log"

    /// The last applied runtime pixel size.
    public func debugCurrentPixelSize() -> (width: UInt32, height: UInt32) {
        (lastPixelWidth, lastPixelHeight)
    }

    /// The desired focus state mirror.
    public func debugDesiredFocusState() -> Bool {
        desiredFocusState
    }

    /// The additional environment (test hook).
    @MainActor
    public func debugAdditionalEnvironmentForTesting() -> [String: String] {
        additionalEnvironment
    }

    /// How many force refreshes ran since the last reset.
    public func debugForceRefreshCount() -> Int {
        debugForceRefreshCountLock.lock()
        defer { debugForceRefreshCountLock.unlock() }
        return debugForceRefreshCountValue
    }

    /// Resets the force-refresh counter.
    @MainActor
    public func resetDebugForceRefreshCount() {
        debugForceRefreshCountLock.lock()
        debugForceRefreshCountValue = 0
        debugForceRefreshCountLock.unlock()
    }

    func recordDebugForceRefresh() {
        debugForceRefreshCountLock.lock()
        debugForceRefreshCountValue += 1
        debugForceRefreshCountLock.unlock()
    }

    static func surfaceLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: surfaceLogPath) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return }
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            FileManager.default.createFile(atPath: surfaceLogPath, contents: line.data(using: .utf8))
        }
    }

    static func sizeLog(_ message: String) {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] == "1" else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: sizeLogPath) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return }
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            FileManager.default.createFile(atPath: sizeLogPath, contents: line.data(using: .utf8))
        }
    }
#endif

#if DEBUG
    /// Overrides `needsConfirmClose()` for tests.
    @MainActor
    public func setNeedsConfirmCloseOverrideForTesting(_ value: Bool?) {
        needsConfirmCloseOverrideForTesting = value
    }

    /// How many runtime-surface create attempts ran (test hook).
    @MainActor
    public func debugRuntimeSurfaceCreateAttemptCountForTesting() -> Int {
        runtimeSurfaceCreateAttemptCountForTesting
    }

    /// Whether a background surface start is queued (test hook).
    @MainActor
    public func debugBackgroundSurfaceStartQueuedForTesting() -> Bool {
        backgroundSurfaceStartQueued
    }

    /// The input currently primed for the next runtime spawn (test hook).
    @MainActor
    public func debugNextRuntimeInitialInputForTesting() -> String? {
        nextRuntimeInitialInput
    }

    /// Whether the hidden bootstrap window exists (test hook).
    @MainActor
    public func debugHasHeadlessStartupWindowForTesting() -> Bool {
        headlessStartupWindow != nil
    }

    /// Pending socket-input queue accounting (test hook).
    @MainActor
    public func debugPendingSocketInputForTesting() -> (
        items: Int,
        bytes: Int,
        keyEvents: Int,
        pasteTextItems: Int,
        inputTextItems: Int,
        processOutputItems: Int
    ) {
        let counts = pendingSocketInputQueue.reduce(
            into: (keyEvents: 0, pasteTextItems: 0, inputTextItems: 0, processOutputItems: 0)
        ) { counts, item in
            switch item {
            case .key:
                counts.keyEvents += 1
            case .pasteText:
                counts.pasteTextItems += 1
            case .inputText:
                counts.inputTextItems += 1
            case .processOutput:
                counts.processOutputItems += 1
            }
        }
        return (
            pendingSocketInputQueue.count,
            pendingSocketInputBytes,
            counts.keyEvents,
            counts.pasteTextItems,
            counts.inputTextItems,
            counts.processOutputItems
        )
    }

    /// Test-only helper to deterministically simulate a released runtime surface.
    @MainActor
    public func releaseSurfaceForTesting() {
        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil

        guard let surfaceToFree = surface else {
            callbackContext?.release()
            return
        }

        registry.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        surface = nil
        ghostty_surface_free(surfaceToFree)
        callbackContext?.release()
    }

    /// Test-only helper to simulate a stale Swift wrapper whose native surface
    /// was already freed out-of-band.
    @MainActor
    public func replaceSurfaceWithFreedPointerForTesting() {
        guard !runtimeSurfaceFreedOutOfBandForTesting else { return }

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil

        guard let surfaceToFree = surface else {
            callbackContext?.release()
            return
        }

        registry.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        ghostty_surface_free(surfaceToFree)
        runtimeSurfaceFreedOutOfBandForTesting = true
        callbackContext?.release()
    }

    /// Test-only helper to install a runtime surface pointer directly.
    @MainActor
    public func installRuntimeSurfaceForTesting(_ runtimeSurface: ghostty_surface_t) {
        surface = runtimeSurface
        portalLifecycleState = .live
        runtimeSurfaceFreedOutOfBandForTesting = false
    }
#endif
}
