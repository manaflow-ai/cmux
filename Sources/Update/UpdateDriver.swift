import Cocoa
import Sparkle

/// SPUUserDriver that updates the view model for custom update UI.
class UpdateDriver: NSObject, SPUUserDriver {
    let viewModel: UpdateViewModel
    private let minimumCheckDuration: TimeInterval
    private let stateTimeoutDuration: TimeInterval
    private var lastCheckStart: Date?
    private var pendingCheckTransition: DispatchWorkItem?
    private var stateTimeoutWorkItem: DispatchWorkItem?
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
         stateTimeoutDuration: TimeInterval = UpdateTiming.stateTimeoutDuration) {
        self.viewModel = viewModel
        self.minimumCheckDuration = minimumCheckDuration
        self.stateTimeoutDuration = stateTimeoutDuration
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
        UpdateLogStore.shared.append("show update found: \(appcastItem.displayVersionString)")
        runOnMain { [weak self] in
            guard let self else {
                reply(.dismiss)
                return
            }
            guard !operationHasTimedOut else {
                UpdateLogStore.shared.append("dismissing update found after timeout")
                reply(.dismiss)
                return
            }
            setStateAfterMinimumCheckDelay(.updateAvailable(.init(appcastItem: appcastItem, reply: reply)))
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
            guard !operationHasTimedOut else {
                UpdateLogStore.shared.append("acknowledging update not found after timeout")
                acknowledgement()
                return
            }
            setStateAfterMinimumCheckDelay(.notFound(.init(acknowledgement: acknowledgement)))
        }
    }

    func showUpdaterError(_ error: any Error,
                          acknowledgement: @escaping () -> Void) {
        let details = formatErrorForLog(error)
        UpdateLogStore.shared.append("show updater error: \(details)")
        setState(.error(.init(
            error: error,
            retry: { [weak viewModel] in
                viewModel?.state = .idle
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
        )))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        UpdateLogStore.shared.append("show download initiated")
        runOnMain { [weak self] in
            guard let self else {
                cancellation()
                return
            }
            guard !operationHasTimedOut else {
                UpdateLogStore.shared.append("cancelling download after timeout")
                cancellation()
                return
            }
            setState(.downloading(.init(
                cancel: cancellation,
                expectedLength: nil,
                progress: 0)),
                timeoutStage: .downloading,
                timeoutCancellation: cancellation)
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        UpdateLogStore.shared.append("download expected length: \(expectedContentLength)")
        runOnMain { [weak self] in
            guard let self else { return }
            guard !operationHasTimedOut else {
                UpdateLogStore.shared.append("ignoring download expected length after timeout")
                return
            }
            guard case let .downloading(downloading) = viewModel.state else {
                return
            }

            setState(.downloading(.init(
                cancel: downloading.cancel,
                expectedLength: expectedContentLength,
                progress: 0)),
                timeoutStage: .downloading,
                timeoutCancellation: downloading.cancel)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        UpdateLogStore.shared.append("download received data: \(length)")
        runOnMain { [weak self] in
            guard let self else { return }
            guard !operationHasTimedOut else {
                UpdateLogStore.shared.append("ignoring download data after timeout")
                return
            }
            guard case let .downloading(downloading) = viewModel.state else {
                return
            }

            setState(.downloading(.init(
                cancel: downloading.cancel,
                expectedLength: downloading.expectedLength,
                progress: downloading.progress + length)),
                timeoutStage: .downloading,
                timeoutCancellation: downloading.cancel)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        UpdateLogStore.shared.append("show extraction started")
        setState(.extracting(.init(progress: 0)), timeoutStage: .preparing)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        UpdateLogStore.shared.append(String(format: "show extraction progress: %.2f", progress))
        setState(.extracting(.init(progress: progress)), timeoutStage: .preparing)
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        UpdateLogStore.shared.append("show ready to install")
        runOnMain { [weak self] in
            guard let self else {
                reply(.dismiss)
                return
            }
            guard !operationHasTimedOut else {
                UpdateLogStore.shared.append("ignoring ready to install after timeout")
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
        )))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        UpdateLogStore.shared.append("show update installed (relaunched=\(relaunched))")
        setState(.idle)
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
        setState(.idle)
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
            lastCheckStart = Date()
            applyState(.checking(.init(cancel: cancel)))
            scheduleStateTimeout(stage: .checking, cancellation: cancel)
        }
    }

    private func setStateAfterMinimumCheckDelay(_ newState: UpdateState) {
        runOnMain { [weak self] in
            guard let self else { return }
            pendingCheckTransition?.cancel()
            pendingCheckTransition = nil
            cancelStateTimeout()
            guard !operationHasTimedOut else {
                UpdateLogStore.shared.append("ignoring delayed state after timeout: \(describe(newState))")
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
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard case .checking = self.viewModel.state else { return }
                guard !self.operationHasTimedOut else {
                    UpdateLogStore.shared.append("ignoring delayed check result after timeout: \(self.describe(newState))")
                    return
                }
                self.lastCheckStart = nil
                self.applyState(newState)
            }
            pendingCheckTransition = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func setState(_ newState: UpdateState,
                          timeoutStage: TimeoutStage? = nil,
                          timeoutCancellation: (() -> Void)? = nil) {
        runOnMain { [weak self] in
            guard let self else { return }
            pendingCheckTransition?.cancel()
            pendingCheckTransition = nil
            cancelStateTimeout()
            guard !operationHasTimedOut else {
                UpdateLogStore.shared.append("ignoring state after timeout: \(describe(newState))")
                return
            }
            lastCheckStart = nil
            applyState(newState)
            if let timeoutStage {
                scheduleStateTimeout(stage: timeoutStage, cancellation: timeoutCancellation)
            }
        }
    }

    private var operationHasTimedOut: Bool {
        timedOutOperationGeneration == currentOperationGeneration
    }

    private func cancelStateTimeout() {
        stateTimeoutWorkItem?.cancel()
        stateTimeoutWorkItem = nil
    }

    private func scheduleStateTimeout(stage: TimeoutStage, cancellation: (() -> Void)? = nil) {
        let generation = currentOperationGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.failOperationIfStillCurrent(stage: stage, generation: generation, cancellation: cancellation)
        }
        stateTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + stateTimeoutDuration, execute: workItem)
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

        UpdateLogStore.shared.append("\(stage.logName) timed out after \(Int(stateTimeoutDuration.rounded()))s")
        timedOutOperationGeneration = generation
        pendingCheckTransition?.cancel()
        pendingCheckTransition = nil
        stateTimeoutWorkItem = nil
        lastCheckStart = nil
        cancellation?()
        applyState(.error(.init(
            error: UpdateTimeoutError.make(stage: stage.errorStage),
            retry: { [weak viewModel] in
                viewModel?.state = .idle
                DispatchQueue.main.async {
                    guard let delegate = NSApp.delegate as? AppDelegate else { return }
                    delegate.checkForUpdates(nil)
                }
            },
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            },
            technicalDetails: "\(stage.logName) timed out after \(Int(stateTimeoutDuration.rounded()))s",
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
