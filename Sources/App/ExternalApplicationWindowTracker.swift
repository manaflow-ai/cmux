import AppKit
import CoreGraphics

/// Reports the active window geometry for one external macOS application.
///
/// The tracker observes application activation on the main actor. After it finds
/// the target window, public global mouse-drag events request immediate samples.
/// A bounded 120 Hz poll covers non-mouse moves and missed events.
@MainActor
final class ExternalApplicationWindowTracker {
    struct Snapshot: Equatable, Sendable {
        let windowID: CGWindowID
        let ownerProcessIdentifier: pid_t
        let frame: CGRect
    }

    enum Event: Equatable, Sendable {
        case visible(Snapshot)
        case hidden
        case unavailable
    }

    struct Dependencies: Sendable {
        let frontWindow: @Sendable (
            _ processIdentifier: pid_t,
            _ primaryScreenMaxY: CGFloat
        ) -> Snapshot?
        let window: @Sendable (
            _ windowID: CGWindowID,
            _ processIdentifier: pid_t,
            _ primaryScreenMaxY: CGFloat
        ) -> Snapshot?
        let sleep: @Sendable (_ duration: Duration) async throws -> Void

        static let live = Dependencies(
            frontWindow: { processIdentifier, primaryScreenMaxY in
                ExternalApplicationWindowTracker.frontWindowSnapshot(
                    processIdentifier: processIdentifier,
                    primaryScreenMaxY: primaryScreenMaxY
                )
            },
            window: { windowID, processIdentifier, primaryScreenMaxY in
                ExternalApplicationWindowTracker.windowSnapshot(
                    windowID: windowID,
                    processIdentifier: processIdentifier,
                    primaryScreenMaxY: primaryScreenMaxY
                )
            },
            sleep: { duration in
                try await ContinuousClock().sleep(for: duration)
            }
        )
    }

    private let bundleIdentifier: String
    private let primaryScreenMaxY: CGFloat
    private let workspace: NSWorkspace
    private let dependencies: Dependencies
    private let acquisitionInterval: Duration
    private let acquisitionAttemptLimit: Int
    private let missingSampleLimit: Int
    private let automaticUpdatesEnabled: Bool

    private var activationTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var acquisitionTask: Task<Void, Never>?
    private var mouseDragMonitor: Any?
    private var pollingDriver: ExternalWindowPollingDriver?
    private var eventHandler: (@MainActor (Event) -> Void)?
    private var activeProcessIdentifier: pid_t?
    private var trackedWindowID: CGWindowID?
    private var lastSnapshot: Snapshot?
    private var missingSampleCount = 0
    private var generation = UUID()

    init(
        bundleIdentifier: String,
        primaryScreenMaxY: CGFloat,
        workspace: NSWorkspace = .shared,
        dependencies: Dependencies = .live,
        acquisitionInterval: Duration = .milliseconds(50),
        acquisitionAttemptLimit: Int = 100,
        missingSampleLimit: Int = 12,
        automaticUpdatesEnabled: Bool = true
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.primaryScreenMaxY = primaryScreenMaxY
        self.workspace = workspace
        self.dependencies = dependencies
        self.acquisitionInterval = acquisitionInterval
        self.acquisitionAttemptLimit = acquisitionAttemptLimit
        self.missingSampleLimit = missingSampleLimit
        self.automaticUpdatesEnabled = automaticUpdatesEnabled
    }

    /// Starts tracking and calls `eventHandler` directly on the main actor.
    ///
    /// A callback is used instead of an AsyncStream because another main-actor
    /// hop adds visible delay while the target window is being dragged.
    func start(eventHandler: @escaping @MainActor (Event) -> Void) {
        stop()
        self.eventHandler = eventHandler

        activationTask = Task { @MainActor [weak self, workspace] in
            for await notification in workspace.notificationCenter.notifications(
                named: NSWorkspace.didActivateApplicationNotification
            ) {
                guard !Task.isCancelled else { return }
                self?.applicationDidActivate(
                    notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication
                )
            }
        }
        terminationTask = Task { @MainActor [weak self, workspace] in
            for await notification in workspace.notificationCenter.notifications(
                named: NSWorkspace.didTerminateApplicationNotification
            ) {
                guard !Task.isCancelled else { return }
                self?.applicationDidTerminate(
                    notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication
                )
            }
        }
        refreshFrontmostApplication()
    }

    func refreshFrontmostApplication() {
        applicationDidActivate(workspace.frontmostApplication)
    }

    /// Applies an activation event without coupling callers to NSWorkspace.
    func handleApplicationActivation(
        bundleIdentifier activatedBundleIdentifier: String?,
        processIdentifier: pid_t?
    ) {
        guard activatedBundleIdentifier == bundleIdentifier,
              let processIdentifier
        else {
            guard activeProcessIdentifier != nil || acquisitionTask != nil
                    || trackedWindowID != nil
            else {
                emit(.hidden)
                return
            }
            stopTrackingWindow()
            emit(.hidden)
            return
        }

        guard activeProcessIdentifier != processIdentifier
                || (acquisitionTask == nil && trackedWindowID == nil)
        else {
            return
        }
        startTrackingWindow(processIdentifier: processIdentifier)
    }

    func stop() {
        activationTask?.cancel()
        activationTask = nil
        terminationTask?.cancel()
        terminationTask = nil
        stopTrackingWindow()
        eventHandler = nil
    }

    private func applicationDidActivate(_ application: NSRunningApplication?) {
        handleApplicationActivation(
            bundleIdentifier: application?.bundleIdentifier,
            processIdentifier: application?.processIdentifier
        )
    }

    private func applicationDidTerminate(_ application: NSRunningApplication?) {
        guard application?.bundleIdentifier == bundleIdentifier else { return }
        stopTrackingWindow()
        emit(.unavailable)
    }

    private func startTrackingWindow(processIdentifier: pid_t) {
        stopTrackingWindow()
        activeProcessIdentifier = processIdentifier
        let currentGeneration = generation
        let dependencies = dependencies
        let primaryScreenMaxY = primaryScreenMaxY
        let acquisitionInterval = acquisitionInterval
        let acquisitionAttemptLimit = acquisitionAttemptLimit

        acquisitionTask = Task.detached(priority: .userInitiated) { [weak self] in
            var initialSnapshot: Snapshot?
            for _ in 0..<acquisitionAttemptLimit {
                guard !Task.isCancelled else { return }
                if let snapshot = dependencies.frontWindow(
                    processIdentifier,
                    primaryScreenMaxY
                ) {
                    initialSnapshot = snapshot
                    break
                }
                do {
                    try await dependencies.sleep(acquisitionInterval)
                } catch {
                    return
                }
            }

            guard let initialSnapshot else {
                await self?.trackingBecameUnavailable(
                    generation: currentGeneration,
                    processIdentifier: processIdentifier
                )
                return
            }
            await self?.finishWindowAcquisition(
                initialSnapshot,
                generation: currentGeneration,
                processIdentifier: processIdentifier
            )
        }
    }

    private func stopTrackingWindow() {
        acquisitionTask?.cancel()
        acquisitionTask = nil
        stopWindowUpdates()
        activeProcessIdentifier = nil
        trackedWindowID = nil
        lastSnapshot = nil
        missingSampleCount = 0
        generation = UUID()
    }

    private func finishWindowAcquisition(
        _ initialSnapshot: Snapshot,
        generation expectedGeneration: UUID,
        processIdentifier: pid_t
    ) {
        guard generation == expectedGeneration,
              activeProcessIdentifier == processIdentifier,
              eventHandler != nil
        else {
            return
        }
        acquisitionTask = nil
        trackedWindowID = initialSnapshot.windowID
        lastSnapshot = initialSnapshot
        missingSampleCount = 0
        emit(.visible(initialSnapshot))
        if automaticUpdatesEnabled {
            startWindowUpdates(
                windowID: initialSnapshot.windowID,
                processIdentifier: processIdentifier,
                generation: expectedGeneration
            )
        }
    }

    /// Samples immediately. It is internal so focused tests can prove
    /// synchronous delivery without starting the automatic polling loop.
    func refreshTrackedWindow() {
        guard let processIdentifier = activeProcessIdentifier,
              let windowID = trackedWindowID
        else {
            return
        }
        acceptWindowSample(
            dependencies.window(
                windowID,
                processIdentifier,
                primaryScreenMaxY
            ),
            generation: generation,
            processIdentifier: processIdentifier,
            windowID: windowID
        )
    }

    private func acceptWindowSample(
        _ snapshot: Snapshot?,
        generation expectedGeneration: UUID,
        processIdentifier: pid_t,
        windowID: CGWindowID
    ) {
        guard generation == expectedGeneration,
              activeProcessIdentifier == processIdentifier,
              trackedWindowID == windowID
        else {
            return
        }
        guard let snapshot else {
            missingSampleCount += 1
            if missingSampleCount >= missingSampleLimit {
                trackingBecameUnavailable(
                    generation: expectedGeneration,
                    processIdentifier: processIdentifier
                )
            }
            return
        }

        missingSampleCount = 0
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        emit(.visible(snapshot))
    }

    private func startWindowUpdates(
        windowID: CGWindowID,
        processIdentifier: pid_t,
        generation expectedGeneration: UUID
    ) {
        stopWindowUpdates()

        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTrackedWindow()
            }
        }

        let dependencies = dependencies
        let primaryScreenMaxY = primaryScreenMaxY
        let driver = ExternalWindowPollingDriver(
            sample: {
                dependencies.window(
                    windowID,
                    processIdentifier,
                    primaryScreenMaxY
                )
            },
            deliver: { [weak self] snapshot in
                self?.acceptWindowSample(
                    snapshot,
                    generation: expectedGeneration,
                    processIdentifier: processIdentifier,
                    windowID: windowID
                )
            }
        )
        pollingDriver = driver
        driver.start()
    }

    private func stopWindowUpdates() {
        if let mouseDragMonitor {
            NSEvent.removeMonitor(mouseDragMonitor)
        }
        mouseDragMonitor = nil
        pollingDriver?.stop()
        pollingDriver = nil
    }

    private func emit(_ event: Event) {
        eventHandler?(event)
    }

    private func trackingBecameUnavailable(
        generation expectedGeneration: UUID,
        processIdentifier: pid_t
    ) {
        guard generation == expectedGeneration,
              activeProcessIdentifier == processIdentifier
        else {
            return
        }
        stopTrackingWindow()
        emit(.unavailable)
    }

    private nonisolated static func frontWindowSnapshot(
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

    private nonisolated static func windowSnapshot(
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
        if let isOnScreen = entry[kCGWindowIsOnscreen as String] as? NSNumber,
           !isOnScreen.boolValue {
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
            )
        )
    }
}

/// Keeps one 120 Hz WindowServer read and one main-thread delivery pending.
/// A delayed main thread receives only the newest sampled frame.
private final class ExternalWindowPollingDriver: @unchecked Sendable {
    typealias Snapshot = ExternalApplicationWindowTracker.Snapshot

    private static let interval = DispatchTimeInterval.nanoseconds(8_333_333)
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.cmuxterm.external-window-tracker",
        qos: .userInteractive
    )
    private let sample: @Sendable () -> Snapshot?
    private let deliver: @MainActor @Sendable (Snapshot?) -> Void
    private var timer: DispatchSourceTimer?
    private var isActive = false
    private var latestSample: Sample?
    private var deliveryIsPending = false

    private enum Sample: Sendable {
        case visible(Snapshot)
        case missing

        var snapshot: Snapshot? {
            switch self {
            case .visible(let snapshot): snapshot
            case .missing: nil
            }
        }
    }

    init(
        sample: @escaping @Sendable () -> Snapshot?,
        deliver: @escaping @MainActor @Sendable (Snapshot?) -> Void
    ) {
        self.sample = sample
        self.deliver = deliver
    }

    func start() {
        lock.lock()
        guard !isActive else {
            lock.unlock()
            return
        }
        isActive = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        lock.unlock()

        timer.setEventHandler { [weak self] in
            self?.sampleWindow()
        }
        timer.schedule(
            deadline: .now(),
            repeating: Self.interval,
            leeway: .microseconds(250)
        )
        timer.resume()
    }

    func stop() {
        lock.lock()
        let timer = timer
        self.timer = nil
        isActive = false
        latestSample = nil
        lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
    }

    private func sampleWindow() {
        let nextSample = sample().map(Sample.visible) ?? .missing

        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        latestSample = nextSample
        let shouldDeliver = !deliveryIsPending
        deliveryIsPending = true
        lock.unlock()

        if shouldDeliver {
            DispatchQueue.main.async { [weak self] in
                self?.deliverLatestSample()
            }
        }
    }

    private func deliverLatestSample() {
        dispatchPrecondition(condition: .onQueue(.main))

        lock.lock()
        guard isActive else {
            latestSample = nil
            deliveryIsPending = false
            lock.unlock()
            return
        }
        let nextSample = latestSample
        latestSample = nil
        deliveryIsPending = false
        lock.unlock()

        guard let nextSample else { return }
        MainActor.assumeIsolated {
            deliver(nextSample.snapshot)
        }
    }
}
