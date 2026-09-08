import AppKit
import CoreGraphics

/// Reports the active window geometry for one external macOS application.
///
/// The tracker observes application activation on the main actor. Core Graphics
/// window reads run in a detached task so another application's live window drag
/// cannot block this application's UI thread.
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
    private let samplingInterval: Duration
    private let missingSampleLimit: Int

    private var activationTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var samplingTask: Task<Void, Never>?
    private var continuation: AsyncStream<Event>.Continuation?
    private var streamID: UUID?
    private var activeProcessIdentifier: pid_t?
    private var generation = UUID()

    init(
        bundleIdentifier: String,
        primaryScreenMaxY: CGFloat,
        workspace: NSWorkspace = .shared,
        dependencies: Dependencies = .live,
        acquisitionInterval: Duration = .milliseconds(50),
        acquisitionAttemptLimit: Int = 100,
        samplingInterval: Duration = .nanoseconds(16_666_667),
        missingSampleLimit: Int = 6
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.primaryScreenMaxY = primaryScreenMaxY
        self.workspace = workspace
        self.dependencies = dependencies
        self.acquisitionInterval = acquisitionInterval
        self.acquisitionAttemptLimit = acquisitionAttemptLimit
        self.samplingInterval = samplingInterval
        self.missingSampleLimit = missingSampleLimit
    }

    func start() -> AsyncStream<Event> {
        stop()
        let pair = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        let currentStreamID = UUID()
        streamID = currentStreamID
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.stop(streamID: currentStreamID)
            }
        }

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
        return pair.stream
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
            guard activeProcessIdentifier != nil || samplingTask != nil else {
                continuation?.yield(.hidden)
                return
            }
            stopSampling()
            continuation?.yield(.hidden)
            return
        }

        guard activeProcessIdentifier != processIdentifier || samplingTask == nil else {
            return
        }
        startSampling(processIdentifier: processIdentifier)
    }

    func stop() {
        stop(streamID: nil)
    }

    private func stop(streamID expectedStreamID: UUID?) {
        if let expectedStreamID, streamID != expectedStreamID {
            return
        }
        activationTask?.cancel()
        activationTask = nil
        terminationTask?.cancel()
        terminationTask = nil
        stopSampling()
        let activeContinuation = continuation
        continuation = nil
        streamID = nil
        activeContinuation?.finish()
    }

    private func applicationDidActivate(_ application: NSRunningApplication?) {
        handleApplicationActivation(
            bundleIdentifier: application?.bundleIdentifier,
            processIdentifier: application?.processIdentifier
        )
    }

    private func applicationDidTerminate(_ application: NSRunningApplication?) {
        guard application?.bundleIdentifier == bundleIdentifier else { return }
        stopSampling()
        continuation?.yield(.unavailable)
    }

    private func startSampling(processIdentifier: pid_t) {
        stopSampling()
        activeProcessIdentifier = processIdentifier
        let currentGeneration = generation
        let dependencies = dependencies
        let primaryScreenMaxY = primaryScreenMaxY
        let acquisitionInterval = acquisitionInterval
        let acquisitionAttemptLimit = acquisitionAttemptLimit
        let samplingInterval = samplingInterval
        let missingSampleLimit = missingSampleLimit

        samplingTask = Task.detached(priority: .userInitiated) { [weak self] in
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
                await self?.samplingBecameUnavailable(
                    generation: currentGeneration,
                    processIdentifier: processIdentifier
                )
                return
            }
            guard await self?.publish(
                .visible(initialSnapshot),
                generation: currentGeneration,
                processIdentifier: processIdentifier
            ) == true else {
                return
            }

            var lastSnapshot = initialSnapshot
            var missingSampleCount = 0
            while !Task.isCancelled {
                do {
                    try await dependencies.sleep(samplingInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let snapshot = dependencies.window(
                    initialSnapshot.windowID,
                    processIdentifier,
                    primaryScreenMaxY
                ) else {
                    missingSampleCount += 1
                    if missingSampleCount >= missingSampleLimit {
                        await self?.samplingBecameUnavailable(
                            generation: currentGeneration,
                            processIdentifier: processIdentifier
                        )
                        return
                    }
                    continue
                }

                missingSampleCount = 0
                guard snapshot != lastSnapshot else { continue }
                lastSnapshot = snapshot
                guard await self?.publish(
                    .visible(snapshot),
                    generation: currentGeneration,
                    processIdentifier: processIdentifier
                ) == true else {
                    return
                }
            }
        }
    }

    private func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
        activeProcessIdentifier = nil
        generation = UUID()
    }

    private func publish(
        _ event: Event,
        generation expectedGeneration: UUID,
        processIdentifier: pid_t
    ) -> Bool {
        guard generation == expectedGeneration,
              activeProcessIdentifier == processIdentifier,
              continuation != nil
        else {
            return false
        }
        continuation?.yield(event)
        return true
    }

    private func samplingBecameUnavailable(
        generation expectedGeneration: UUID,
        processIdentifier: pid_t
    ) {
        guard generation == expectedGeneration,
              activeProcessIdentifier == processIdentifier
        else {
            return
        }
        stopSampling()
        continuation?.yield(.unavailable)
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
        let requestedWindowIDs = [windowID] as CFArray
        guard let windowInfo = CGWindowListCreateDescriptionFromArray(
            requestedWindowIDs
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
