import AppKit
import Combine
import Darwin
import Foundation

// MARK: - Dedupe decision (pure, injectable)

/// Pure focus-activation policy for the computer-use "watch the target" feature.
///
/// A computer-use agent runs as a background CLI process, which macOS will not
/// reliably let front an app over the currently-active GUI app (cmux). cmux *is*
/// the active app, so cmux fronts the driven target on the driver's behalf — but
/// only when a *new* target starts being driven, never on every action.
enum ComputerUseWatchTargetDecision {
    /// Returns the target pid cmux should bring to the front, or `nil` to do nothing.
    ///
    /// The rule is intentionally minimal so it never fights the user's focus:
    /// - `current == nil` (no session is actively driving) -> `nil`, and the caller
    ///   keeps `lastActivated` unchanged. This is what makes a brief idle gap
    ///   between actions harmless: when the same target resumes, it still equals
    ///   `lastActivated`, so we do not re-front it.
    /// - `current == lastActivated` (the same app keeps being driven) -> `nil`.
    ///   Every action rewrites the driver state file and the user may have clicked
    ///   away in the meantime; returning `nil` here is precisely what stops cmux
    ///   from yanking focus back on every click.
    /// - otherwise a *different* app is now being driven -> return `current` so the
    ///   caller activates it once and records it as `lastActivated`.
    static func activation(
        current: Int?,
        lastActivated: Int?,
        automaticActivationEnabled: Bool = true
    ) -> Int? {
        guard automaticActivationEnabled else { return nil }
        guard let current else { return nil }
        if current == lastActivated { return nil }
        return current
    }

    static func activityDisposition(
        isAuthorized: Bool,
        validatedTargetPID: Int?,
        lastActivatedTargetPID: Int?
    ) -> (shouldRetry: Bool, targetPIDToActivate: Int?) {
        guard isAuthorized, let validatedTargetPID else {
            return (true, nil)
        }
        guard let targetPID = ComputerUseWatchTargetDecision.activation(
            current: validatedTargetPID,
            lastActivated: lastActivatedTargetPID
        ) else {
            return (false, nil)
        }
        return (false, targetPID)
    }
}

// MARK: - Fresh-state scanning (pure)

/// Selects the driver state file for the session that is *currently* driving an
/// app, from the same untrusted state directory the cursor overlay watches.
struct ComputerUseWatchTargetFeed: Sendable {
    /// A state file counts as "actively driving" only while its `last_action_at`
    /// is within this window; the driver rewrites the file on every action.
    static let defaultFreshnessInterval: TimeInterval = 5
    private static let maximumFutureClockSkew: TimeInterval = 5 * 60
    private static let maximumFileBytes = 64 * 1_024
    private static let maximumCandidateFiles = 512
    private static let maximumDirectoryEntries = 4_096
    private static let cursorSuffix = ".cursor.json"
    private static let stateSuffix = ".json"

    let freshnessInterval: TimeInterval
    let authenticationKey: Data

    init(
        freshnessInterval: TimeInterval = Self.defaultFreshnessInterval,
        authenticationKey: Data
    ) {
        self.freshnessInterval = freshnessInterval
        self.authenticationKey = authenticationKey
    }

    /// Returns the newest fresh driver activity for every requested live session.
    func scan(
        directoryURL: URL,
        driverSessionIDs: Set<String>,
        now: Date,
        fileManager: FileManager = .default,
        isStateEligible: @Sendable (
            String,
            ComputerUseDriverState
        ) -> Bool = { _, _ in true }
    ) -> [ComputerUseWatchTargetActivity] {
        guard !driverSessionIDs.isEmpty,
            let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        else {
            return []
        }

        var inspectedEntries = 0
        var candidates: [(url: URL, size: Int, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            inspectedEntries += 1
            // Treat a pathologically large directory as unavailable. This state
            // directory is private and normally contains one pair of files per
            // live driver; continuing through attacker-created junk would turn a
            // watcher callback into unbounded CPU and memory work.
            guard inspectedEntries <= Self.maximumDirectoryEntries else { return [] }
            let name = url.lastPathComponent
            // `.cursor.json` files live in the same directory; they never parse as a
            // driver state, but skip them explicitly to keep the scan cheap.
            guard name.hasSuffix(Self.stateSuffix), !name.hasSuffix(Self.cursorSuffix) else { continue }
            guard
                let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ]),
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                let fileSize = values.fileSize,
                fileSize > 0,
                fileSize <= Self.maximumFileBytes
            else {
                continue
            }
            candidates.append((
                url,
                fileSize,
                values.contentModificationDate ?? .distantPast
            ))
        }
        candidates.sort { $0.modifiedAt > $1.modifiedAt }

        var newestByDriverSessionID: [String: ComputerUseWatchTargetActivity] = [:]
        for candidate in candidates.prefix(Self.maximumCandidateFiles) {
            guard
                let data = try? Data(contentsOf: candidate.url, options: [.mappedIfSafe]),
                data.count == candidate.size,
                data.count <= Self.maximumFileBytes,
                let state = ComputerUseDriverState(
                    data: data,
                    authenticationKey: authenticationKey
                ),
                let driverSessionID = Self.matchingDriverSessionID(
                    state.session,
                    allowed: driverSessionIDs
                ),
                isFresh(state.lastActionAt, now: now),
                isStateEligible(driverSessionID, state)
            else {
                continue
            }
            let activity = ComputerUseWatchTargetActivity(
                driverSessionID: driverSessionID,
                state: state
            )
            if let current = newestByDriverSessionID[driverSessionID],
               current.lastActionAt >= activity.lastActionAt {
                continue
            }
            newestByDriverSessionID[driverSessionID] = activity
        }
        return newestByDriverSessionID.values.sorted { lhs, rhs in
            if lhs.lastActionAt == rhs.lastActionAt {
                return lhs.driverSessionID < rhs.driverSessionID
            }
            return lhs.lastActionAt < rhs.lastActionAt
        }
    }

    private static func matchingDriverSessionID(
        _ candidate: String?,
        allowed: Set<String>
    ) -> String? {
        guard let candidate else { return nil }
        if allowed.contains(candidate) {
            return candidate
        }
        guard let marker = candidate.range(of: "-mcp-") else { return nil }
        let base = String(candidate[..<marker.lowerBound])
        return allowed.contains(base) ? base : nil
    }

    func isFresh(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -Self.maximumFutureClockSkew && age <= freshnessInterval
    }
}

// MARK: - Controller

/// Brings the app a local computer-use driver is steering to the front so the
/// user can actually watch the automation, instead of seeing the cmux-hosted
/// cursor click on top of cmux while the real target stays hidden behind it.
///
/// Fronts each distinct target exactly once (`ComputerUseWatchTargetDecision`)
/// so it never competes with the user's own focus while a session runs. Gated by
/// `featureEnabled` and validated with `ComputerUseTargetIdentity`, mirroring the
/// menu bar's "View Computer Use" action and the cursor overlay's watcher shape.
/// Choosing "Continue in Background" pauses automatic activation until the user
/// explicitly returns to the target or the active session ends.
@MainActor
final class ComputerUseWatchTargetController {
    private let stateDirectoryURL: URL
    private let featureEnabled: @MainActor () -> Bool
    /// Maps each surface-derived driver session ID to the logical agent session
    /// currently occupying that surface.
    private let liveDriverSessions:
        @MainActor () -> [String: ComputerUseLiveDriverSession]
    /// Reconstructs one exact live-index entry by its workspace/surface key.
    /// Interactive actions use this O(1) path instead of rebuilding every agent.
    private let currentLiveDriverSession:
        @MainActor (ComputerUseLiveDriverSession) -> ComputerUseLiveDriverSession?
    private let feed: ComputerUseWatchTargetFeed
    private let activate: @MainActor (NSRunningApplication) -> Void

    /// Background/focus presentation is retained independently for every live
    /// driver session, so activity in one agent cannot rewrite another's choice.
    private var backgroundDriverSessionIDs: Set<String> = []
    private var observedDriverSessions: [String: ComputerUseLiveDriverSession] = [:]

    /// The most recently fronted target for each driver session. Keeping this per
    /// session preserves focus deduplication through idle gaps and interleaved
    /// activity from other agents.
    private var lastActivatedTargetPIDByDriverSessionID: [String: Int] = [:]
    private var lastObservedActionAtByDriverSessionID: [String: Date] = [:]

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    private let directoryWatchQueue = DispatchQueue(label: "com.cmuxterm.app.computerUseWatchTarget")
    /// The untrusted state directory is scanned here, never on the main thread.
    private let scanQueue = DispatchQueue(label: "com.cmuxterm.app.computerUseWatchTargetScan", qos: .utility)
    /// At most one background scan is outstanding; further ticks are dropped until
    /// it lands. A one-bit latch preserves one follow-up refresh for any writes
    /// that arrive after the active scan took its filesystem snapshot.
    private var scanInFlight = false
    private var scanRequestedWhileInFlight = false
    private var cancellables: Set<AnyCancellable> = []
    private var refreshCoalesceScheduled = false
    private var refreshCoalesceTask: Task<Void, Never>?
    private var directoryWatchRetryTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var started = false

    init(
        stateDirectoryURL: URL,
        featureEnabled: @escaping @MainActor () -> Bool,
        liveDriverSessions:
            @escaping @MainActor () -> [String: ComputerUseLiveDriverSession],
        currentLiveDriverSession:
            @escaping @MainActor (
                ComputerUseLiveDriverSession
            ) -> ComputerUseLiveDriverSession?,
        feed: ComputerUseWatchTargetFeed,
        activate: @escaping @MainActor (NSRunningApplication) -> Void = { application in
            // NSRunningApplication.activate no longer reliably fronts another app
            // on macOS 14+ (cooperative-activation changes make it a frequent
            // no-op). NSWorkspace.openApplication on the already-running app's
            // bundle brings it genuinely to the front — no Apple Events permission
            // needed — which is what "watch the automation" requires.
            if let bundleURL = application.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(
                    at: bundleURL,
                    configuration: configuration,
                    completionHandler: nil
                )
            } else {
                _ = application.activate(options: [.activateAllWindows])
            }
        }
    ) {
        self.stateDirectoryURL = stateDirectoryURL
        self.featureEnabled = featureEnabled
        self.liveDriverSessions = liveDriverSessions
        self.currentLiveDriverSession = currentLiveDriverSession
        self.feed = feed
        self.activate = activate
    }

    deinit {
        refreshCoalesceTask?.cancel()
        directoryWatchRetryTask?.cancel()
        directoryWatchSource?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        scanGeneration &+= 1

        NotificationCenter.default.publisher(for: .cmuxFeatureFlagsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.reconcileObservation() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .sharedLiveAgentIndexDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.reconcileObservation() }
            }
            .store(in: &cancellables)

        reconcileObservation()
    }

    func stop() {
        started = false
        cancellables.removeAll()
        suspendObservation()
        observedDriverSessions.removeAll()
        lastActivatedTargetPIDByDriverSessionID.removeAll()
        lastObservedActionAtByDriverSessionID.removeAll()
        backgroundDriverSessionIDs.removeAll()
    }

    /// Preserves the originating terminal as the user's foreground context.
    @discardableResult
    func continueInBackground(
        driverSessionID: String,
        logicalSessionID: String,
        stateWriterIdentity: AgentPIDProcessIdentity
    ) -> Bool {
        guard canControlSession(
            driverSessionID: driverSessionID,
            logicalSessionID: logicalSessionID,
            stateWriterIdentity: stateWriterIdentity
        ) else {
            return false
        }
        backgroundDriverSessionIDs.insert(driverSessionID)
        return true
    }

    /// Revalidates a menu action against the exact current live agent process
    /// tree before it can mutate the corresponding helper session.
    func canControlSession(
        driverSessionID: String,
        logicalSessionID: String,
        stateWriterIdentity: AgentPIDProcessIdentity
    ) -> Bool {
        guard
            let liveSession = revalidatedLiveSession(
                driverSessionID: driverSessionID,
                logicalSessionID: logicalSessionID
            ),
            ComputerUseDriverState.process(
                stateWriterIdentity,
                belongsToProcessTree: liveSession.rootProcessIdentities
            )
        else {
            return false
        }
        return true
    }

    func isRunningInBackground(
        driverSessionID: String,
        logicalSessionID: String
    ) -> Bool {
        guard revalidatedLiveSession(
            driverSessionID: driverSessionID,
            logicalSessionID: logicalSessionID
        ) != nil
        else {
            return false
        }
        return backgroundDriverSessionIDs.contains(driverSessionID)
    }

    /// Fronts a validated target and resumes automatic following for new targets.
    @discardableResult
    func viewTarget(
        _ identity: ComputerUseTargetIdentity,
        driverSessionID: String,
        logicalSessionID: String,
        stateWriterIdentity: AgentPIDProcessIdentity
    ) -> Bool {
        guard
            canViewTarget(
                identity,
                driverSessionID: driverSessionID,
                logicalSessionID: logicalSessionID,
                stateWriterIdentity: stateWriterIdentity
            ),
            let pid = pid_t(exactly: identity.processIdentifier),
            let application = NSRunningApplication(processIdentifier: pid)
        else {
            return false
        }

        backgroundDriverSessionIDs.remove(driverSessionID)
        activate(application)
        lastActivatedTargetPIDByDriverSessionID[driverSessionID] =
            identity.processIdentifier
        return true
    }

    /// Reports whether a captured target still identifies the same running app.
    func canViewTarget(
        _ identity: ComputerUseTargetIdentity,
        driverSessionID: String,
        logicalSessionID: String,
        stateWriterIdentity: AgentPIDProcessIdentity
    ) -> Bool {
        guard
            let liveSession = revalidatedLiveSession(
                driverSessionID: driverSessionID,
                logicalSessionID: logicalSessionID
            ),
            ComputerUseDriverState.process(
                stateWriterIdentity,
                belongsToProcessTree: liveSession.rootProcessIdentities
            ),
            let pid = pid_t(exactly: identity.processIdentifier)
        else {
            return false
        }
        return identity.matches(NSRunningApplication(processIdentifier: pid))
    }

    func refresh() {
        guard started,
              featureEnabled(),
              !observedDriverSessions.isEmpty
        else {
            return
        }

        // Never scan the untrusted state directory on the main thread. The driver
        // rewrites its state files many times per second while driving, so doing
        // the directory enumeration + JSON reads inline here floods the main
        // thread with synchronous filesystem I/O and beachballs the app during
        // active computer use. Run the I/O on a utility queue and validate +
        // activate back on the main actor with the small `Sendable` snapshot;
        // `scanInFlight` collapses a burst of watcher events into one scan.
        guard !scanInFlight else {
            scanRequestedWhileInFlight = true
            return
        }
        scanInFlight = true
        scanRequestedWhileInFlight = false
        let generation = scanGeneration
        let feed = self.feed
        let directoryURL = self.stateDirectoryURL
        let driverSessions = observedDriverSessions
        let driverSessionIDs = Set(driverSessions.keys)
        let scanDate = Date()
        scanQueue.async(execute: Self.makeScanOperation(
            feed: feed,
            directoryURL: directoryURL,
            driverSessions: driverSessions,
            driverSessionIDs: driverSessionIDs,
            scanDate: scanDate,
            generation: generation,
            controller: self
        ))
    }

    /// The scan queue cannot synchronously enter this `@MainActor` controller.
    /// Construct the callback outside the actor, then hop back with its value.
    nonisolated private static func makeScanOperation(
        feed: ComputerUseWatchTargetFeed,
        directoryURL: URL,
        driverSessions: [String: ComputerUseLiveDriverSession],
        driverSessionIDs: Set<String>,
        scanDate: Date,
        generation: Int,
        controller: ComputerUseWatchTargetController
    ) -> @Sendable () -> Void {
        { [weak controller] in
            let activities = feed.scan(
                directoryURL: directoryURL,
                driverSessionIDs: driverSessionIDs,
                now: scanDate
            ) { driverSessionID, state in
                    guard
                        let liveSession = driverSessions[driverSessionID]
                    else {
                        return false
                    }
                    return state.belongsToProcessTree(
                        rootProcessIdentities: liveSession.rootProcessIdentities
                    )
            }
            Task { @MainActor [weak controller] in
                guard let controller else { return }
                controller.scanInFlight = false
                let needsFollowUp = controller.scanRequestedWhileInFlight
                controller.scanRequestedWhileInFlight = false
                if generation == controller.scanGeneration {
                    controller.applyScannedActivities(activities)
                }
                if needsFollowUp {
                    controller.refresh()
                }
            }
        }
    }

    private func applyScannedActivities(
        _ activities: [ComputerUseWatchTargetActivity]
    ) {
        guard started, featureEnabled() else { return }
        let newlyUpdated = activities.filter { activity in
            let previous =
                lastObservedActionAtByDriverSessionID[activity.driverSessionID]
                ?? .distantPast
            return activity.lastActionAt > previous
        }
        guard let newest = newlyUpdated.last else { return }

        // A newest background event may not starve another newly-updated
        // foreground session. Otherwise, never fall back from a deduped/invalid
        // newest foreground event to older still-fresh activity.
        let activity = backgroundDriverSessionIDs.contains(newest.driverSessionID)
            ? newlyUpdated.last {
                !backgroundDriverSessionIDs.contains($0.driverSessionID)
            }
            : newest
        for nonSelected in newlyUpdated where
            nonSelected.driverSessionID != activity?.driverSessionID
        {
            advanceWatermark(for: nonSelected)
        }
        guard let activity else { return }
        let driverSessionID = activity.driverSessionID
        let scannedSession = observedDriverSessions[driverSessionID]
        let currentSession = scannedSession.flatMap {
            currentLiveDriverSession($0)
        }
        let isAuthorized: Bool
        if let scannedSession, let currentSession {
            isAuthorized = scannedSession.authorizes(
                state: activity.state,
                currentSession: currentSession
            )
        } else {
            isAuthorized = false
        }
        let target = isAuthorized
            ? validatedTarget(from: activity.state)
            : nil
        let disposition = ComputerUseWatchTargetDecision.activityDisposition(
            isAuthorized: isAuthorized,
            validatedTargetPID: target?.pid,
            lastActivatedTargetPID:
                lastActivatedTargetPIDByDriverSessionID[driverSessionID]
        )

        if disposition.shouldRetry {
            // Process metadata and LaunchServices can be briefly unavailable
            // while an app launches. Do not consume the state until validation
            // succeeds; the feed's freshness window bounds these retries.
            scheduleCoalescedRefresh()
            return
        }
        guard let targetPID = disposition.targetPIDToActivate else {
            // The exact same valid target was already fronted. This is a
            // definitive dedupe, so advancing the watermark is safe.
            advanceWatermark(for: activity)
            return
        }
        guard let application = target?.application else {
            scheduleCoalescedRefresh()
            return
        }
        activate(application)
        // Record the attempt regardless of the activation return value so a
        // target that resists activation is not re-fronted on every event.
        lastActivatedTargetPIDByDriverSessionID[driverSessionID] = targetPID
        advanceWatermark(for: activity)
    }

    private func revalidatedLiveSession(
        driverSessionID: String,
        logicalSessionID: String
    ) -> ComputerUseLiveDriverSession? {
        guard
            let scannedSession = observedDriverSessions[driverSessionID],
            scannedSession.logicalSessionID == logicalSessionID,
            let currentSession = currentLiveDriverSession(scannedSession),
            currentSession.logicalSessionID == logicalSessionID
        else {
            return nil
        }
        return currentSession
    }

    private func advanceWatermark(
        for activity: ComputerUseWatchTargetActivity
    ) {
        let previous =
            lastObservedActionAtByDriverSessionID[activity.driverSessionID]
            ?? .distantPast
        if activity.lastActionAt > previous {
            lastObservedActionAtByDriverSessionID[activity.driverSessionID] =
                activity.lastActionAt
        }
    }

    private func reconcileObservation() {
        guard started else { return }
        let liveSessions = liveDriverSessions()
        let liveDriverSessionIDs = Set(liveSessions.keys)
        let replacedDriverSessionIDs = Set<String>(liveSessions.compactMap {
            driverSessionID,
            liveSession -> String? in
            observedDriverSessions[driverSessionID]?.logicalSessionID
                == liveSession.logicalSessionID
                ? nil
                : driverSessionID
        })

        backgroundDriverSessionIDs.formIntersection(liveDriverSessionIDs)
        lastActivatedTargetPIDByDriverSessionID =
            lastActivatedTargetPIDByDriverSessionID.filter {
                liveDriverSessionIDs.contains($0.key)
            }
        lastObservedActionAtByDriverSessionID =
            lastObservedActionAtByDriverSessionID.filter {
                liveDriverSessionIDs.contains($0.key)
            }
        for driverSessionID in replacedDriverSessionIDs {
            backgroundDriverSessionIDs.remove(driverSessionID)
            lastActivatedTargetPIDByDriverSessionID.removeValue(
                forKey: driverSessionID
            )
            // A replacement gets a fresh event watermark. State is accepted
            // only when its writer belongs to the replacement's process tree,
            // which rejects both leftover files and a lingering prior proxy
            // without discarding a valid first action written before the live
            // index published the transition.
            lastObservedActionAtByDriverSessionID.removeValue(
                forKey: driverSessionID
            )
        }

        let sessionsChanged = liveSessions != observedDriverSessions
        observedDriverSessions = liveSessions

        guard featureEnabled(), !liveSessions.isEmpty else {
            suspendObservation()
            return
        }

        ensureStateDirectoryObservation()
        if sessionsChanged {
            scanGeneration &+= 1
        }
        refresh()
    }

    private func suspendObservation() {
        scanGeneration &+= 1
        scanRequestedWhileInFlight = false
        refreshCoalesceTask?.cancel()
        refreshCoalesceTask = nil
        refreshCoalesceScheduled = false
        directoryWatchRetryTask?.cancel()
        directoryWatchRetryTask = nil
        directoryWatchSource?.cancel()
        directoryWatchSource = nil
    }

    /// Validates the scanned driver state's target against liveness + identity to
    /// reject reused/stale pids. Returns `nil` when nothing is driving or the
    /// target fails validation. Runs on the main actor (touches `NSRunningApplication`).
    private func validatedTarget(
        from state: ComputerUseDriverState?
    ) -> (pid: Int, application: NSRunningApplication)? {
        guard
            let state,
            let pid = pid_t(exactly: state.targetPID),
            // Never front cmux itself — only the external app under automation.
            pid != ProcessInfo.processInfo.processIdentifier,
            let application = NSRunningApplication(processIdentifier: pid),
            ComputerUseTargetIdentity(state: state, runningApplication: application) != nil
        else {
            return nil
        }
        return (Int(pid), application)
    }

    private func ensureStateDirectoryObservation() {
        guard started, featureEnabled(), !observedDriverSessions.isEmpty else {
            return
        }
        if startWatchingStateDirectory() {
            directoryWatchRetryTask?.cancel()
            directoryWatchRetryTask = nil
        } else {
            scheduleDirectoryWatchRetry()
        }
    }

    @discardableResult
    private func startWatchingStateDirectory() -> Bool {
        guard directoryWatchSource == nil else { return true }
        try? FileManager.default.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true
        )
        let descriptor = open(stateDirectoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete],
            queue: directoryWatchQueue
        )
        source.setEventHandler(handler: Self.makeDirectoryWatchEventHandler(
            source: source,
            controller: self
        ))
        source.setCancelHandler(handler: Self.makeDirectoryWatchCancelHandler(
            descriptor: descriptor
        ))
        source.resume()
        directoryWatchSource = source
        return true
    }

    /// DispatchSource delivers on its own queue. Constructing this closure from a
    /// nonisolated context prevents Swift 6 from inheriting `@MainActor` and
    /// trapping before the explicit actor hop can run.
    nonisolated private static func makeDirectoryWatchEventHandler(
        source: DispatchSourceFileSystemObject,
        controller: ComputerUseWatchTargetController
    ) -> @Sendable () -> Void {
        { [weak source, weak controller] in
            guard let source else { return }
            let events = source.data
            Task { @MainActor [weak controller] in
                controller?.handleDirectoryWatchEvent(
                    events,
                    from: source
                )
            }
        }
    }

    nonisolated private static func makeDirectoryWatchCancelHandler(
        descriptor: Int32
    ) -> @Sendable () -> Void {
        { Darwin.close(descriptor) }
    }

    private func handleDirectoryWatchEvent(
        _ events: DispatchSource.FileSystemEvent,
        from source: DispatchSourceFileSystemObject
    ) {
        guard directoryWatchSource === source else { return }
        if events.contains(.delete) || events.contains(.rename) {
            source.cancel()
            directoryWatchSource = nil
            if startWatchingStateDirectory() {
                directoryWatchRetryTask?.cancel()
                directoryWatchRetryTask = nil
                scheduleCoalescedRefresh()
            } else {
                scheduleDirectoryWatchRetry()
            }
            return
        }
        scheduleCoalescedRefresh()
    }

    private func scheduleDirectoryWatchRetry() {
        guard directoryWatchRetryTask == nil else { return }
        directoryWatchRetryTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let delays: [Duration] = [
                .milliseconds(100),
                .milliseconds(250),
                .milliseconds(500),
                .seconds(1),
                .seconds(2),
                .seconds(5),
                .seconds(10),
                .seconds(30),
            ]
            var attempt = 0
            while true {
                // One owner task retries with capped backoff. This preserves
                // recovery after transient descriptor exhaustion without
                // creating timers/tasks per filesystem event.
                let delay = delays[min(attempt, delays.count - 1)]
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
                guard
                    let self,
                    self.started,
                    self.featureEnabled(),
                    !self.observedDriverSessions.isEmpty,
                    !Task.isCancelled
                else {
                    return
                }
                if self.startWatchingStateDirectory() {
                    self.directoryWatchRetryTask = nil
                    self.refresh()
                    return
                }
                attempt += 1
            }
        }
    }

    /// Coalesce a burst of filesystem events into at most one refresh per ~quarter
    /// second. The driver rewrites its state file on every action; this only needs
    /// to notice a *new* target, so refreshing on every raw event would needlessly
    /// flood the main thread during active computer use.
    private func scheduleCoalescedRefresh() {
        guard started, !refreshCoalesceScheduled else { return }
        refreshCoalesceScheduled = true
        refreshCoalesceTask = Task { @MainActor [weak self] in
            do {
                // Genuine bounded debounce for one burst of directory events.
                try await ContinuousClock().sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, self.started, !Task.isCancelled else { return }
            self.refreshCoalesceScheduled = false
            self.refreshCoalesceTask = nil
            self.refresh()
        }
    }
}
