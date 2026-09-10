import AppKit
import CoreGraphics

/// Tracks one external window throughout a permission flow, including while
/// another application is active. Mouse events deliver synchronous drag updates;
/// bounded metadata sampling covers window creation, keyboard moves and closure
/// without requiring Accessibility permission from the host app.
@MainActor
final class ExternalApplicationWindowTracker {
    typealias Snapshot = ExternalApplicationWindowSnapshot
    typealias Event = ExternalApplicationWindowEvent
    typealias Dependencies = ExternalApplicationWindowDependencies

    private let bundleIdentifier: String
    private let primaryScreenMaxY: @Sendable () -> CGFloat
    private let workspace: NSWorkspace
    private let dependencies: Dependencies
    private let acquisitionAttemptLimit: Int
    private let missingSampleLimit: Int
    private let automaticUpdatesEnabled: Bool
    private let sampler = ExternalWindowSamplingService()

    private var activationTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var mouseDragLifetime: Task<Void, Never>?
    private var eventHandler: (@MainActor (Event) -> Void)?
    private var targetProcessIdentifier: pid_t?
    private var targetIsActive = false
    private var trackedWindowID: CGWindowID?
    private var lastSnapshot: Snapshot?
    private var acquisitionAttemptCount = 0
    private var missingSampleCount = 0
    private var lastSampleStartedAt: UInt64 = 0
    private var generation = UUID()

    init(
        bundleIdentifier: String,
        primaryScreenMaxY: @escaping @Sendable () -> CGFloat = {
            CGDisplayBounds(CGMainDisplayID()).height
        },
        workspace: NSWorkspace = .shared,
        dependencies: Dependencies = .live,
        acquisitionAttemptLimit: Int = 100,
        missingSampleLimit: Int = 12,
        automaticUpdatesEnabled: Bool = true
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.primaryScreenMaxY = primaryScreenMaxY
        self.workspace = workspace
        self.dependencies = dependencies
        self.acquisitionAttemptLimit = acquisitionAttemptLimit
        self.missingSampleLimit = missingSampleLimit
        self.automaticUpdatesEnabled = automaticUpdatesEnabled
    }

    deinit {
        activationTask?.cancel()
        terminationTask?.cancel()
        mouseDragLifetime?.cancel()
    }

    /// Direct main-actor delivery avoids an extra scheduling hop during a drag.
    func start(eventHandler: @escaping @MainActor (Event) -> Void) {
        stop()
        self.eventHandler = eventHandler
        activationTask = Task { @MainActor [weak self, workspace] in
            for await notification in workspace.notificationCenter.notifications(
                named: NSWorkspace.didActivateApplicationNotification
            ) {
                guard !Task.isCancelled else { return }
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                self?.handleApplicationActivation(
                    bundleIdentifier: application?.bundleIdentifier,
                    processIdentifier: application?.processIdentifier
                )
            }
        }
        terminationTask = Task { @MainActor [weak self, workspace] in
            for await notification in workspace.notificationCenter.notifications(
                named: NSWorkspace.didTerminateApplicationNotification
            ) {
                guard !Task.isCancelled else { return }
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                self?.handleApplicationTermination(processIdentifier: application?.processIdentifier)
            }
        }
        refreshFrontmostApplication()
    }

    func refreshFrontmostApplication() {
        let application = workspace.frontmostApplication
        handleApplicationActivation(
            bundleIdentifier: application?.bundleIdentifier,
            processIdentifier: application?.processIdentifier
        )
    }

    func handleApplicationActivation(
        bundleIdentifier activatedBundleIdentifier: String?,
        processIdentifier: pid_t?
    ) {
        guard activatedBundleIdentifier == bundleIdentifier, let processIdentifier else {
            targetIsActive = false
            if trackedWindowID == nil {
                stopTrackingWindow()
            } else {
                // Keep observing the acquired window: the retained companion
                // must not outlive it. Background reads drop to four per second.
                startSampling()
            }
            eventHandler?(.hidden)
            return
        }
        let wasActive = targetIsActive
        targetIsActive = true
        if targetProcessIdentifier == processIdentifier {
            if !wasActive { startSampling() }
            refreshTrackedWindow()
            return
        }
        stopTrackingWindow()
        targetProcessIdentifier = processIdentifier
        targetIsActive = true
        refreshTrackedWindow()
        if trackedWindowID == nil, targetProcessIdentifier != nil {
            startSampling()
        }
    }

    func stop() {
        activationTask?.cancel()
        activationTask = nil
        terminationTask?.cancel()
        terminationTask = nil
        stopTrackingWindow()
        eventHandler = nil
    }

    func handleApplicationTermination(processIdentifier: pid_t?) {
        guard let processIdentifier, processIdentifier == targetProcessIdentifier else { return }
        stopTrackingWindow()
        eventHandler?(.unavailable)
    }

    private func stopTrackingWindow() {
        sampler.stop()
        mouseDragLifetime?.cancel()
        mouseDragLifetime = nil
        targetProcessIdentifier = nil
        targetIsActive = false
        trackedWindowID = nil
        lastSnapshot = nil
        acquisitionAttemptCount = 0
        missingSampleCount = 0
        lastSampleStartedAt = 0
        generation = UUID()
    }

    /// Refreshes the acquired window directly for a public mouse event, or
    /// attempts initial acquisition after the target application activates.
    func refreshTrackedWindow() {
        guard let processIdentifier = targetProcessIdentifier else { return }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let primaryScreenMaxY = primaryScreenMaxY()
        let snapshot: Snapshot?
        if let windowID = trackedWindowID {
            snapshot = dependencies.window(windowID, processIdentifier, primaryScreenMaxY)
        } else {
            snapshot = dependencies.frontWindow(processIdentifier, primaryScreenMaxY)
        }
        acceptWindowSample(.init(startedAt: startedAt, snapshot: snapshot))
    }

    private func acceptWindowSample(_ sample: ExternalWindowSample) {
        // A delayed background read must never move the panel back over a more
        // recent synchronous drag update.
        guard sample.startedAt >= lastSampleStartedAt else { return }
        lastSampleStartedAt = sample.startedAt
        guard let snapshot = sample.snapshot else {
            if trackedWindowID == nil {
                acquisitionAttemptCount += 1
                if acquisitionAttemptCount < acquisitionAttemptLimit { return }
            } else {
                missingSampleCount += 1
                if missingSampleCount < missingSampleLimit { return }
            }
            stopTrackingWindow()
            eventHandler?(.unavailable)
            return
        }
        guard snapshot.ownerProcessIdentifier == targetProcessIdentifier else { return }
        missingSampleCount = 0
        if let windowID = trackedWindowID {
            guard snapshot.windowID == windowID else { return }
        } else {
            trackedWindowID = snapshot.windowID
            if automaticUpdatesEnabled {
                let expectedGeneration = generation
                let monitor = NSEvent.addGlobalMonitorForEvents(
                    matching: [.leftMouseDragged, .leftMouseUp]
                ) { [weak self] _ in
                    // AppKit guarantees global event monitors run on main.
                    MainActor.assumeIsolated {
                        guard self?.targetIsActive == true,
                              self?.generation == expectedGeneration else { return }
                        self?.refreshTrackedWindow()
                    }
                }
                if let monitor {
                    // Cancellation owns cleanup on main, even if the tracker
                    // is released elsewhere. Mouse delivery itself stays direct.
                    let lifetime = AsyncStream<Void> { _ in }
                    mouseDragLifetime = Task { @MainActor in
                        defer { NSEvent.removeMonitor(monitor) }
                        for await _ in lifetime {}
                    }
                }
            }
        }
        guard snapshot != lastSnapshot else { return }
        let visibilityChanged = lastSnapshot?.isOnScreen != snapshot.isOnScreen
        lastSnapshot = snapshot
        if visibilityChanged { startSampling() }
        eventHandler?(snapshot.isOnScreen ? .visible(snapshot) : .offscreen)
    }

    private func startSampling() {
        guard automaticUpdatesEnabled, let processIdentifier = targetProcessIdentifier else { return }
        let expectedGeneration = generation
        let windowID = trackedWindowID
        let dependencies = dependencies
        let primaryScreenMaxY = primaryScreenMaxY
        let interval: DispatchTimeInterval
        if windowID == nil {
            interval = .milliseconds(50)
        } else {
            interval = targetIsActive && lastSnapshot?.isOnScreen != false
                ? .nanoseconds(8_333_333) : .milliseconds(250)
        }
        sampler.start(
            interval: interval,
            sample: {
                if let windowID {
                    return dependencies.window(windowID, processIdentifier, primaryScreenMaxY())
                }
                return dependencies.frontWindow(processIdentifier, primaryScreenMaxY())
            },
            deliver: { [weak self] sample in
                guard let self,
                      self.generation == expectedGeneration,
                      self.trackedWindowID == windowID
                else { return }
                self.acceptWindowSample(sample)
            }
        )
    }

    nonisolated static func frontWindowSnapshot(
        processIdentifier: pid_t,
        primaryScreenMaxY: CGFloat
    ) -> Snapshot? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return windowInfo.compactMap {
            snapshot(
                from: $0,
                expectedWindowID: nil,
                processIdentifier: processIdentifier,
                primaryScreenMaxY: primaryScreenMaxY
            )
        }.max { lhs, rhs in
            lhs.frame.width * lhs.frame.height
                < rhs.frame.width * rhs.frame.height
        }
    }

    nonisolated static func windowSnapshot(
        windowID: CGWindowID,
        processIdentifier: pid_t,
        primaryScreenMaxY: CGFloat
    ) -> Snapshot? {
        // CGWindowListCreateDescriptionFromArray returns an empty result for a
        // valid external window on macOS 26. The including-window query uses
        // the same public metadata and returns the requested record reliably.
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            windowID
        ) as? [[String: Any]] else {
            return nil
        }
        return windowInfo.compactMap {
            snapshot(
                from: $0,
                expectedWindowID: windowID,
                processIdentifier: processIdentifier,
                primaryScreenMaxY: primaryScreenMaxY
            )
        }.first
    }

    private nonisolated static func snapshot(
        from entry: [String: Any],
        expectedWindowID: CGWindowID?,
        processIdentifier: pid_t,
        primaryScreenMaxY: CGFloat
    ) -> Snapshot? {
        guard let ownerPID = entry[kCGWindowOwnerPID as String] as? NSNumber,
              pid_t(ownerPID.int32Value) == processIdentifier,
              let layer = entry[kCGWindowLayer as String] as? NSNumber,
              layer.intValue == 0,
              let windowNumber = entry[kCGWindowNumber as String] as? NSNumber,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let quartzFrame = CGRect(dictionaryRepresentation: bounds)
        else {
            return nil
        }
        let windowID = CGWindowID(windowNumber.uint32Value)
        if let expectedWindowID, windowID != expectedWindowID {
            return nil
        }
        return Snapshot(
            windowID: windowID,
            ownerProcessIdentifier: processIdentifier,
            frame: CGRect(
                x: quartzFrame.minX,
                y: primaryScreenMaxY - quartzFrame.maxY,
                width: quartzFrame.width,
                height: quartzFrame.height
            ),
            isOnScreen: (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
        )
    }
}
