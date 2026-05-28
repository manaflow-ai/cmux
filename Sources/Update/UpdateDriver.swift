import Cocoa
import Sparkle

/// SPUUserDriver that updates the view model for custom update UI.
class UpdateDriver: NSObject, SPUUserDriver {
    let viewModel: UpdateViewModel
    var updateCycleDidFinish: (() -> Void)?
    private let minimumCheckDuration: TimeInterval
    private let checkingTimeoutDuration: TimeInterval
    private let downloadingTimeoutDuration: TimeInterval
    private let preparingTimeoutDuration: TimeInterval
    private let scheduler: UpdateOperationScheduling
    private var lastCheckStart: Date?
    private var pendingCheckTransition: UpdateScheduledAction?
    private var stateTimeoutAction: UpdateScheduledAction?
    private var currentOperationGeneration: Int = 0
    private var timedOutOperationGeneration: Int?
    private var lastFeedURLString: String?

    private enum TimeoutStage {
        case checking
        case downloading
        case preparing

        var errorStage: UpdateTimeoutError.Stage {
            switch self {
            case .checking: return .checking
            case .downloading: return .downloading
            case .preparing: return .preparing
            }
        }

        var logName: String {
            switch self {
            case .checking: return "checking"
            case .downloading: return "downloading"
            case .preparing: return "preparing"
            }
        }
    }

    init(viewModel: UpdateViewModel,
         hostBundle _: Bundle,
         minimumCheckDuration: TimeInterval = UpdateTiming.minimumCheckDisplayDuration,
         stateTimeoutDuration: TimeInterval? = nil,
         scheduler: UpdateOperationScheduling = DispatchUpdateOperationScheduler.shared) {
        self.viewModel = viewModel
        self.minimumCheckDuration = minimumCheckDuration
        self.checkingTimeoutDuration = stateTimeoutDuration ?? UpdateTiming.checkingTimeoutDuration
        self.downloadingTimeoutDuration = stateTimeoutDuration ?? UpdateTiming.downloadingInactivityTimeoutDuration
        self.preparingTimeoutDuration = stateTimeoutDuration ?? UpdateTiming.preparingTimeoutDuration
        self.scheduler = scheduler
        super.init()
    }

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" || env["CMUX_UI_TEST_AUTO_ALLOW_PERMISSION"] == "1" {
            UpdateLogStore.shared.append("auto-allow update permission (ui test)")
            DispatchQueue.main.async {
                reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
            }
            return
        }
#endif
        // Never show Sparkle's permission UI. cmux always enables scheduled checks and keeps
        // automatic downloads disabled so installs remain user-driven.
        UpdateLogStore.shared.append("auto-allow update permission (no UI)")
        DispatchQueue.main.async {
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
        }
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        UpdateLogStore.shared.append("show user-initiated update check")
        beginChecking(cancel: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        showUpdateFound(with: appcastItem, userInitiated: state.userInitiated, reply: reply)
    }

    func showUpdateFoundForTesting(with appcastItem: SUAppcastItem,
                                   userInitiated: Bool,
                                   reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        showUpdateFound(with: appcastItem, userInitiated: userInitiated, reply: reply)
    }

    private func showUpdateFound(with appcastItem: SUAppcastItem,
                                 userInitiated: Bool,
                                 reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        UpdateLogStore.shared.append("show update found: \(appcastItem.displayVersionString)")
        runOnMain { [weak self] in
            guard let self else {
                reply(.dismiss)
                return
            }
            var generation = currentOperationGeneration
            if operationHasTimedOut {
                if userInitiated, isCheckingState(viewModel.state) {
                    generation = acceptUserRetryResultAfterTimedOutOperation(resultDescription: "update found")
                } else if !userInitiated {
                    generation = acceptBackgroundResultAfterTimedOutOperation(resultDescription: "update found")
                }
            }
            guard callbackCanMutateState(generation: generation, resultDescription: "update found") else {
                reply(.dismiss)
                return
            }
            setStateAfterMinimumCheckDelay(.updateAvailable(.init(appcastItem: appcastItem, reply: reply)), generation: generation)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // cmux uses Sparkle's UI for release notes links instead.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // Release notes are handled via link buttons.
    }

    func showUpdateNotFoundWithError(_ error: any Error,
                                     acknowledgement: @escaping () -> Void) {
        UpdateLogStore.shared.append("show update not found: \(formatErrorForLog(error))")
        runOnMain { [weak self] in
            guard let self else {
                acknowledgement()
                return
            }
            let generation = currentOperationGeneration
            guard callbackCanMutateState(generation: generation, resultDescription: "update not found") else {
                acknowledgement()
                return
            }
            setStateAfterMinimumCheckDelay(.notFound(.init(acknowledgement: acknowledgement)), generation: generation)
        }
    }

    func showUpdaterError(_ error: any Error,
                          acknowledgement: @escaping () -> Void) {
        let details = formatErrorForLog(error)
        UpdateLogStore.shared.append("show updater error: \(details)")
        setState(.error(.init(
            error: error,
            retry: {
                DispatchQueue.main.async {
                    guard let delegate = NSApp.delegate as? AppDelegate else { return }
                    delegate.checkForUpdates(nil)
                }
            },
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            },
            technicalDetails: details,
            feedURLString: lastFeedURLString
        )), generation: currentOperationGeneration)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        UpdateLogStore.shared.append("show download initiated")
        runOnMain { [weak self] in
            guard let self else {
                cancellation()
                return
            }
            let generation = currentOperationGeneration
            guard callbackCanMutateState(generation: generation, resultDescription: "download initiation") else {
                cancellation()
                return
            }
            setState(.downloading(.init(
                cancel: cancellation,
                expectedLength: nil,
                progress: 0)),
                generation: generation,
                timeoutStage: .downloading,
                timeoutCancellation: cancellation)
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        UpdateLogStore.shared.append("download expected length: \(expectedContentLength)")
        runOnMain { [weak self] in
            guard let self else { return }
            let generation = currentOperationGeneration
            guard callbackCanMutateState(generation: generation, resultDescription: "download expected length") else {
                return
            }
            guard case let .downloading(downloading) = viewModel.state else {
                return
            }

            setState(.downloading(.init(
                cancel: downloading.cancel,
                expectedLength: expectedContentLength,
                progress: 0)),
                generation: generation,
                timeoutStage: .downloading,
                timeoutCancellation: downloading.cancel)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        UpdateLogStore.shared.append("download received data: \(length)")
        runOnMain { [weak self] in
            guard let self else { return }
            let generation = currentOperationGeneration
            guard callbackCanMutateState(generation: generation, resultDescription: "download data") else {
                return
            }
            guard case let .downloading(downloading) = viewModel.state else {
                return
            }

            setState(.downloading(.init(
                cancel: downloading.cancel,
                expectedLength: downloading.expectedLength,
                progress: downloading.progress + length)),
                generation: generation,
                timeoutStage: .downloading,
                timeoutCancellation: downloading.cancel)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        UpdateLogStore.shared.append("show extraction started")
        runOnMain { [weak self] in
            guard let self else { return }
            let generation = currentOperationGeneration
            guard callbackCanMutateState(generation: generation, resultDescription: "extraction start") else {
                return
            }
            setState(.extracting(.init(progress: 0)), generation: generation, timeoutStage: .preparing)
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        UpdateLogStore.shared.append(String(format: "show extraction progress: %.2f", progress))
        runOnMain { [weak self] in
            guard let self else { return }
            let generation = currentOperationGeneration
            guard callbackCanMutateState(generation: generation, resultDescription: "extraction progress") else {
                return
            }
            setState(.extracting(.init(progress: progress)), generation: generation, timeoutStage: .preparing)
        }
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        UpdateLogStore.shared.append("show ready to install")
        runOnMain { [weak self] in
            guard let self else {
                reply(.dismiss)
                return
            }
            let generation = currentOperationGeneration
            guard callbackCanMutateState(generation: generation, resultDescription: "ready to install") else {
                reply(.dismiss)
                return
            }
            cancelStateTimeout()
            reply(.install)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        UpdateLogStore.shared.append("show installing update")
        setState(.installing(.init(
            retryTerminatingApplication: retryTerminatingApplication,
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            }
        )), generation: currentOperationGeneration)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        UpdateLogStore.shared.append("show update installed (relaunched=\(relaunched))")
        setState(.idle, generation: currentOperationGeneration)
        acknowledgement()
    }

    func showUpdateInFocus() {
        // No-op; cmux never shows Sparkle dialogs.
    }

    func dismissUpdateInstallation() {
        UpdateLogStore.shared.append("dismiss update installation")
        if case .error = viewModel.state {
            UpdateLogStore.shared.append("dismiss update installation ignored (error visible)")
            return
        }
        if case .notFound = viewModel.state {
            UpdateLogStore.shared.append("dismiss update installation ignored (notFound visible)")
            return
        }
        if case .checking = viewModel.state {
            UpdateLogStore.shared.append("dismiss update installation ignored (checking)")
            return
        }
        setState(.idle, generation: currentOperationGeneration)
    }

    private func beginChecking(cancel: @escaping () -> Void) {
        runOnMain { [weak self] in
            guard let self else { return }
            viewModel.overrideState = nil
            pendingCheckTransition?.cancel()
            pendingCheckTransition = nil
            cancelStateTimeout()
            currentOperationGeneration += 1
            timedOutOperationGeneration = nil
            let generation = currentOperationGeneration
            lastCheckStart = Date()
            applyState(.checking(.init(cancel: cancel, waitsForCancellation: true)))
            scheduleStateTimeout(stage: .checking, generation: generation, cancellation: cancel)
        }
    }

    private func setStateAfterMinimumCheckDelay(_ newState: UpdateState, generation: Int) {
        runOnMain { [weak self] in
            guard let self else { return }
            pendingCheckTransition?.cancel()
            pendingCheckTransition = nil
            cancelStateTimeout()
            guard callbackCanMutateState(generation: generation, resultDescription: "delayed state \(describe(newState))") else {
                return
            }

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
            pendingCheckTransition = scheduler.schedule(after: delay) { [weak self] in
                guard let self else { return }
                guard case .checking = self.viewModel.state else { return }
                guard self.callbackCanMutateState(generation: generation, resultDescription: "delayed check result \(self.describe(newState))") else {
                    return
                }
                self.lastCheckStart = nil
                self.applyState(newState)
            }
        }
    }

    private func setState(_ newState: UpdateState,
                          generation: Int,
                          timeoutStage: TimeoutStage? = nil,
                          timeoutCancellation: (() -> Void)? = nil) {
        runOnMain { [weak self] in
            guard let self else { return }
            pendingCheckTransition?.cancel()
            pendingCheckTransition = nil
            cancelStateTimeout()
            guard callbackCanMutateState(generation: generation, resultDescription: "state \(describe(newState))") else {
                return
            }
            lastCheckStart = nil
            applyState(newState)
            if let timeoutStage {
                scheduleStateTimeout(stage: timeoutStage, generation: generation, cancellation: timeoutCancellation)
            }
        }
    }

    private var operationHasTimedOut: Bool {
        timedOutOperationGeneration == currentOperationGeneration
    }

    private func isCheckingState(_ state: UpdateState) -> Bool {
        switch state {
        case .checking:
            return true
        default:
            return false
        }
    }

    private func callbackCanMutateState(generation: Int, resultDescription: String) -> Bool {
        guard generation == currentOperationGeneration else {
            UpdateLogStore.shared.append("ignoring stale \(resultDescription) for generation \(generation); current generation is \(currentOperationGeneration)")
            return false
        }
        guard timedOutOperationGeneration != generation else {
            UpdateLogStore.shared.append("ignoring \(resultDescription) after timeout")
            return false
        }
        return true
    }

    private func acceptBackgroundResultAfterTimedOutOperation(resultDescription: String) -> Int {
        UpdateLogStore.shared.append("accepting background \(resultDescription) after timed out user operation")
        return acceptResultAfterTimedOutOperation()
    }

    private func acceptUserRetryResultAfterTimedOutOperation(resultDescription: String) -> Int {
        UpdateLogStore.shared.append("accepting user retry \(resultDescription) after timed out operation")
        return acceptResultAfterTimedOutOperation()
    }

    private func acceptResultAfterTimedOutOperation() -> Int {
        timedOutOperationGeneration = nil
        currentOperationGeneration += 1
        pendingCheckTransition?.cancel()
        pendingCheckTransition = nil
        cancelStateTimeout()
        lastCheckStart = nil
        return currentOperationGeneration
    }

    private func cancelStateTimeout() {
        stateTimeoutAction?.cancel()
        stateTimeoutAction = nil
    }

    private func scheduleStateTimeout(stage: TimeoutStage,
                                      generation: Int,
                                      cancellation: (() -> Void)? = nil) {
        stateTimeoutAction = scheduler.schedule(after: timeoutDuration(for: stage)) { [weak self] in
            guard let self else { return }
            self.failOperationIfStillCurrent(stage: stage, generation: generation, cancellation: cancellation)
        }
    }

    private func timeoutDuration(for stage: TimeoutStage) -> TimeInterval {
        switch stage {
        case .checking:
            return checkingTimeoutDuration
        case .downloading:
            return downloadingTimeoutDuration
        case .preparing:
            return preparingTimeoutDuration
        }
    }

    private func failOperationIfStillCurrent(stage: TimeoutStage,
                                             generation: Int,
                                             cancellation: (() -> Void)?) {
        guard generation == currentOperationGeneration else { return }
        guard !operationHasTimedOut else { return }
        switch stage {
        case .checking:
            guard case .checking = viewModel.state else { return }
        case .downloading:
            guard case .downloading = viewModel.state else { return }
        case .preparing:
            guard case .extracting = viewModel.state else { return }
        }

        let timeoutDuration = timeoutDuration(for: stage)
        UpdateLogStore.shared.append("\(stage.logName) timed out after \(Int(timeoutDuration.rounded()))s")
        timedOutOperationGeneration = generation
        pendingCheckTransition?.cancel()
        pendingCheckTransition = nil
        stateTimeoutAction?.cancel()
        stateTimeoutAction = nil
        lastCheckStart = nil
        cancellation?()
        applyState(.error(.init(
            error: UpdateTimeoutError.make(stage: stage.errorStage),
            retry: {
                DispatchQueue.main.async {
                    guard let delegate = NSApp.delegate as? AppDelegate else { return }
                    delegate.checkForUpdates(nil)
                }
            },
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            },
            technicalDetails: "\(stage.logName) timed out after \(Int(timeoutDuration.rounded()))s",
            feedURLString: lastFeedURLString
        )))
    }

    private func applyState(_ newState: UpdateState) {
        viewModel.applyDriverState(newState)
        UpdateLogStore.shared.append("state -> \(describe(newState))")
    }

    func resolvedFeedURLString() -> String? {
        lastFeedURLString
    }

    func recordFeedURLString(_ feedURLString: String, usedFallback: Bool) {
        if lastFeedURLString == feedURLString {
            return
        }
        lastFeedURLString = feedURLString
        let suffix = usedFallback ? " (fallback)" : ""
        UpdateLogStore.shared.append("feed url resolved\(suffix): \(feedURLString)")
    }

    func formatErrorForLog(_ error: Error) -> String {
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

    private func runOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
}
