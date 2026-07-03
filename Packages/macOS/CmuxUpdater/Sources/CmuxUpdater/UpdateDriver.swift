import Foundation
@preconcurrency import Sparkle

/// The `SPUUserDriver` that translates Sparkle's update lifecycle into ``UpdateStateModel``
/// transitions for cmux's custom (non-Sparkle-UI) update surface.
///
/// Sparkle's `SPUUserDriver`/`SPUUpdaterDelegate` are `@MainActor`, so every callback runs on
/// the main actor and writes the model directly with no thread hopping. The minimum-display
/// and check-timeout delays are bounded, cancellable ``UpdateClock`` tasks. Host actions the
/// driver cannot perform itself (retry, relaunch prep) go through ``UpdateActionDelegate``.
@MainActor
final class UpdateDriver: NSObject, @preconcurrency SPUUserDriver {
    /// The state model this driver drives.
    let model: UpdateStateModel
    let log: any UpdateLogging
    private let clock: any UpdateClock
    /// Whether the running build is a cmux DEV/staging build that is not on the public release
    /// train. When `true`, the driver must never surface the public appcast's update pill (see
    /// ``UpdateController/isDevLikeBundleIdentifier(_:)``).
    let isDevLikeBundle: Bool
    /// Host actions the driver delegates upward. Held weak; set by ``UpdateController``.
    weak var actionDelegate: (any UpdateActionDelegate)?

    private let minimumCheckDuration: TimeInterval = UpdateTiming.minimumCheckDisplayDuration
    private let checkTimeoutDuration: TimeInterval = UpdateTiming.checkTimeoutDuration
    private var lastCheckStart: Date?
    private var pendingCheckTransitionTask: Task<Void, Never>?
    private var checkTimeoutTask: Task<Void, Never>?
    private(set) var lastFeedURLString: String?
    private var pendingPromptDismissCallbacks = 0

    init(model: UpdateStateModel, log: any UpdateLogging, clock: any UpdateClock, isDevLikeBundle: Bool = false) {
        self.model = model
        self.log = log
        self.clock = clock
        self.isDevLikeBundle = isDevLikeBundle
        super.init()
    }

    deinit {
        pendingCheckTransitionTask?.cancel()
        checkTimeoutTask?.cancel()
    }

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" || env["CMUX_UI_TEST_AUTO_ALLOW_PERMISSION"] == "1" {
            log.append("auto-allow update permission (ui test)")
            Task { @MainActor in reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false)) }
            return
        }
#endif
        // Never show Sparkle's permission UI. cmux always enables scheduled checks and keeps
        // automatic downloads disabled so installs remain user-driven.
        log.append("auto-allow update permission (no UI)")
        Task { @MainActor in reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false)) }
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        log.append("show user-initiated update check")
        beginChecking(cancel: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        log.append("show update found: \(appcastItem.displayVersionString)")
        setStateAfterMinimumCheckDelay(.updateAvailable(.init(appcastItem: appcastItem, reply: { [weak self] choice in
            if choice == .dismiss {
                MainActor.assumeIsolated {
                    self?.recordPromptDismissCallbackExpected()
                }
            }
            reply(choice)
        })))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // cmux uses Sparkle's UI for release notes links instead.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // Release notes are handled via link buttons.
    }

    func showUpdateNotFoundWithError(_ error: any Error,
                                     acknowledgement: @escaping () -> Void) {
        log.append("show update not found: \(formatErrorForLog(error))")
        setStateAfterMinimumCheckDelay(.notFound(.init(acknowledgement: acknowledgement)))
    }

    func showUpdaterError(_ error: any Error,
                          acknowledgement: @escaping () -> Void) {
        let details = formatErrorForLog(error)
        log.append("show updater error: \(details)")
        setState(.error(.init(
            error: error,
            retry: { [weak self] in
                self?.model.setState(.idle)
                self?.actionDelegate?.updaterRequestsRetryCheckForUpdates()
            },
            dismiss: { [weak self] in
                self?.model.setState(.idle)
            },
            technicalDetails: details,
            feedURLString: lastFeedURLString
        )))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        log.append("show download initiated")
        setState(.downloading(.init(
            cancel: { [weak self] in
                cancellation()
                if case .downloading = self?.model.state {
                    self?.model.setState(.idle)
                }
            },
            expectedLength: nil,
            progress: 0)))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        log.append("download expected length: \(expectedContentLength)")
        guard case let .downloading(downloading) = model.state else {
            return
        }
        setState(.downloading(.init(
            cancel: downloading.cancel,
            expectedLength: expectedContentLength,
            progress: 0)))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        log.append("download received data: \(length)")
        guard case let .downloading(downloading) = model.state else {
            return
        }
        setState(.downloading(.init(
            cancel: downloading.cancel,
            expectedLength: downloading.expectedLength,
            progress: downloading.progress + length)))
    }

    func showDownloadDidStartExtractingUpdate() {
        log.append("show extraction started")
        setState(.extracting(.init(progress: 0)))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        log.append(String(format: "show extraction progress: %.2f", progress))
        setState(.extracting(.init(progress: progress)))
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        log.append("show ready to install")
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        log.append("show installing update")
        setState(.installing(.init(
            retryTerminatingApplication: retryTerminatingApplication,
            dismiss: { [weak self] in
                self?.model.setState(.idle)
            }
        )))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        log.append("show update installed (relaunched=\(relaunched))")
        setState(.idle)
        acknowledgement()
    }

    func showUpdateInFocus() {
        // No-op; cmux never shows Sparkle dialogs.
    }

    func dismissUpdateInstallation() {
        log.append("dismiss update installation")
        let isExpectedPromptDismissCallback = takePromptDismissCallbackIfExpected()
        if case .error = model.state {
            log.append("dismiss update installation ignored (error visible)")
            return
        }
        if case .notFound = model.state {
            log.append("dismiss update installation ignored (notFound visible)")
            return
        }
        if case .checking = model.state {
            log.append("dismiss update installation ignored (checking)")
            return
        }
        if case .updateAvailable(let available) = model.state, !available.reply.isConsumed {
            // An unanswered prompt cannot be the one this dismissal belongs to: Sparkle dismisses
            // a session after its reply (or abort), so this callback is a stale session's — for
            // example the pre-attempt prompt's dismissal landing after the fresh check already
            // resolved. Dropping to idle here would clobber a live prompt the user (or the
            // attempt coordinator) is about to answer. Once the prompt IS answered, its own
            // dismissal passes through and clears the state as usual.
            log.append("dismiss update installation ignored (unanswered prompt visible)")
            return
        }
        if isExpectedPromptDismissCallback {
            switch model.state {
            case .downloading, .extracting, .installing:
                log.append("dismiss update installation ignored (superseded prompt dismissal)")
                return
            default:
                break
            }
        }
        setState(.idle)
    }

    func recordPromptDismissCallbackExpected() {
        pendingPromptDismissCallbacks += 1
    }

    private func takePromptDismissCallbackIfExpected() -> Bool {
        guard pendingPromptDismissCallbacks > 0 else { return false }
        pendingPromptDismissCallbacks -= 1
        return true
    }

    // MARK: - State transition helpers

    private func beginChecking(cancel: @escaping () -> Void) {
        model.setOverrideState(nil)
        pendingCheckTransitionTask?.cancel()
        pendingCheckTransitionTask = nil
        checkTimeoutTask?.cancel()
        checkTimeoutTask = nil
        lastCheckStart = Date()
        applyState(.checking(.init(cancel: cancel)))
        scheduleCheckTimeout()
    }

    private func setStateAfterMinimumCheckDelay(_ newState: UpdateState) {
        pendingCheckTransitionTask?.cancel()
        pendingCheckTransitionTask = nil
        checkTimeoutTask?.cancel()
        checkTimeoutTask = nil

        guard let start = lastCheckStart else {
            lastCheckStart = nil
            applyState(newState)
            return
        }

        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= minimumCheckDuration {
            lastCheckStart = nil
            applyState(newState)
            return
        }

        let delay = minimumCheckDuration - elapsed
        pendingCheckTransitionTask = Task { @MainActor [weak self] in
            // Bounded, cancellable minimum-display delay via the injected clock.
            try? await self?.clock.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            guard case .checking = self.model.state else { return }
            self.lastCheckStart = nil
            self.applyState(newState)
        }
    }

    private func setState(_ newState: UpdateState) {
        pendingCheckTransitionTask?.cancel()
        pendingCheckTransitionTask = nil
        checkTimeoutTask?.cancel()
        checkTimeoutTask = nil
        lastCheckStart = nil
        applyState(newState)
    }

    private func scheduleCheckTimeout() {
        checkTimeoutTask?.cancel()
        checkTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Bounded, cancellable check-timeout deadline via the injected clock.
            try? await self.clock.sleep(for: .seconds(self.checkTimeoutDuration))
            guard !Task.isCancelled else { return }
            guard case .checking = self.model.state else { return }
            self.setState(.notFound(.init(acknowledgement: {})))
        }
    }

    private func applyState(_ newState: UpdateState) {
        model.applyDriverState(newState)
        log.append("state -> \(describe(newState))")
    }

    // MARK: - Feed URL tracking

    func resolvedFeedURLString() -> String? {
        lastFeedURLString
    }

    func recordFeedURLString(_ feedURLString: String, usedFallback: Bool) {
        if lastFeedURLString == feedURLString {
            return
        }
        lastFeedURLString = feedURLString
        let suffix = usedFallback ? " (fallback)" : ""
        log.append("feed url resolved\(suffix): \(feedURLString)")
    }

    func formatErrorForLog(_ error: any Error) -> String {
        let nsError = error as NSError
        var parts: [String] = ["\(nsError.domain)(\(nsError.code))"]
        if !nsError.localizedDescription.isEmpty {
            parts.append(nsError.localizedDescription)
        }
        if let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            parts.append("url=\(url.absoluteString)")
        } else if let urlString = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            parts.append("url=\(urlString)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            let detail = "\(underlying.domain)(\(underlying.code)) \(underlying.localizedDescription)"
            parts.append("underlying=\(detail)")
        }
        if let feed = lastFeedURLString {
            parts.append("feed=\(feed)")
        }
        return parts.joined(separator: " | ")
    }

    private func describe(_ state: UpdateState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .permissionRequest:
            return "permissionRequest"
        case .checking:
            return "checking"
        case .updateAvailable(let update):
            return "updateAvailable(\(update.appcastItem.displayVersionString))"
        case .notFound:
            return "notFound"
        case .error(let err):
            return "error(\(err.error.localizedDescription))"
        case .downloading(let download):
            if let expected = download.expectedLength, expected > 0 {
                let percent = Double(download.progress) / Double(expected) * 100
                return String(format: "downloading(%.0f%%)", percent)
            }
            return "downloading"
        case .extracting(let extracting):
            return String(format: "extracting(%.0f%%)", extracting.progress * 100)
        case .installing(let installing):
            return "installing(auto=\(installing.isAutoUpdate))"
        }
    }
}
