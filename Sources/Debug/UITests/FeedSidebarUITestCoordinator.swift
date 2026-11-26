#if DEBUG
import AppKit
import Observation

/// Owns the Feed sidebar fixture from window availability through the hook reply.
@MainActor
final class FeedSidebarUITestCoordinator {
    struct RevealResult {
        let revealed: Bool
        let visible: Bool
        let contextFound: Bool
        let stateFound: Bool
        let activeMode: String?
    }

    private let environment: [String: String]
    private let notificationCenter: NotificationCenter
    private weak var windowContextOwner: AnyObject?
    private let reveal: () -> RevealResult?
    private let isPending: (String) -> Bool
    private let pushClient: FeedSidebarUITestPushClient
    private let recordDiagnostics: (String) -> Void
    private let pendingDeadline: @Sendable () async throws -> Void
    private let recorder = FeedSidebarUITestRecorder()
    private var didStart = false
    private var didStartPush = false
    private var pendingRequestId: String?
    private var revealTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    init(
        environment: [String: String],
        notificationCenter: NotificationCenter,
        windowContextOwner: AnyObject,
        reveal: @escaping () -> RevealResult?,
        isPending: @escaping (String) -> Bool,
        pushClient: FeedSidebarUITestPushClient,
        recordDiagnostics: @escaping (String) -> Void,
        pendingDeadline: @escaping @Sendable () async throws -> Void = {
            try await ContinuousClock().sleep(for: .seconds(15))
        }
    ) {
        self.environment = environment
        self.notificationCenter = notificationCenter
        self.windowContextOwner = windowContextOwner
        self.reveal = reveal
        self.isPending = isPending
        self.pushClient = pushClient
        self.recordDiagnostics = recordDiagnostics
        self.pendingDeadline = pendingDeadline
    }

    deinit {
        revealTask?.cancel()
        pushTask?.cancel()
        deadlineTask?.cancel()
    }

    func startIfNeeded() {
        guard !didStart,
              let path = environment["CMUX_UI_TEST_FEED_SIDEBAR_RESULT_PATH"],
              !path.isEmpty else { return }
        didStart = true
        let changes = notificationCenter.notifications(
            named: .mainWindowContextsDidChange,
            object: windowContextOwner
        )
        recorder.write(["stage": "revealOnly"], at: path)
        revealTask = Task { @MainActor [weak self] in
            if self?.attemptReveal(resultPath: path) != false { return }
            for await _ in changes {
                guard !Task.isCancelled else { return }
                if self?.attemptReveal(resultPath: path) != false { return }
            }
        }
    }

    private func attemptReveal(resultPath: String) -> Bool {
        guard let result = reveal() else { return false }
        recorder.write([
            "reveal": result.revealed ? "1" : "0",
            "revealVisible": result.visible ? "1" : "0",
            "revealContextFound": result.contextFound ? "1" : "0",
            "revealStateFound": result.stateFound ? "1" : "0",
            "revealActiveMode": result.activeMode ?? ""
        ], at: resultPath)
        recordDiagnostics(result.revealed ? "feedSidebarUITest.reveal.ok" : "feedSidebarUITest.reveal.pending")
        if result.revealed { startPushIfNeeded(resultPath: resultPath) }
        return result.revealed
    }

    private func startPushIfNeeded(resultPath: String) {
        guard !didStartPush,
              let requestId = environment["CMUX_UI_TEST_FEED_SIDEBAR_REQUEST_ID"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !requestId.isEmpty else { return }
        didStartPush = true
        recorder.write(["pushStarted": "1", "pushRequestId": requestId], at: resultPath)
        pendingRequestId = requestId
        observePending(requestId: requestId, resultPath: resultPath)
        if pendingRequestId != nil {
            let pendingDeadline = pendingDeadline
            // A bounded deadline replaces the legacy 75 polling attempts at 200 ms.
            deadlineTask = Task { @MainActor [weak self] in
                do { try await pendingDeadline() } catch { return }
                guard !Task.isCancelled else { return }
                self?.finishPendingObservation(observed: false, resultPath: resultPath)
            }
        }
        let client = pushClient
        pushTask = Task { @MainActor [weak self] in
            let updates = await client.push(requestId: requestId)
            guard !Task.isCancelled, let self else { return }
            recorder.write(updates, at: resultPath)
            recordDiagnostics("feedSidebarUITest.push.finished")
        }
    }

    private func observePending(requestId: String, resultPath: String) {
        guard pendingRequestId == requestId else { return }
        let pending = withObservationTracking {
            isPending(requestId)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observePending(requestId: requestId, resultPath: resultPath)
            }
        }
        if pending { finishPendingObservation(observed: true, resultPath: resultPath) }
    }

    private func finishPendingObservation(observed: Bool, resultPath: String) {
        guard pendingRequestId != nil else { return }
        pendingRequestId = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        recorder.write(["pushPendingObserved": observed ? "1" : "0"], at: resultPath)
    }
}
#endif
