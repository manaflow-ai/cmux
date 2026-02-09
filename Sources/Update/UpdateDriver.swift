import Cocoa
import Sparkle

/// SPUUserDriver that updates the view model for custom update UI.
class UpdateDriver: NSObject, SPUUserDriver {
    let viewModel: UpdateViewModel
    let standard: SPUStandardUserDriver
    private let minimumCheckDuration: TimeInterval = UpdateTiming.minimumCheckDisplayDuration
    private var lastCheckStart: Date?
    private var pendingCheckTransition: DispatchWorkItem?
    private var checkTimeoutWorkItem: DispatchWorkItem?
    private var lastFeedURLString: String?

    init(viewModel: UpdateViewModel, hostBundle: Bundle) {
        self.viewModel = viewModel
        self.standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        super.init()
    }

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" || env["CMUX_UI_TEST_AUTO_ALLOW_PERMISSION"] == "1" {
            UpdateLogStore.shared.append("auto-allow update permission (ui test)")
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
            return
        }
#endif
        UpdateLogStore.shared.append("show update permission request")
        setState(.permissionRequest(.init(request: request, reply: { [weak viewModel] response in
            viewModel?.state = .idle
            reply(response)
        })))
        if !hasUnobtrusiveTarget {
            standard.show(request, reply: reply)
        }
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        UpdateLogStore.shared.append("show user-initiated update check")
        beginChecking(cancel: cancellation)
        if !hasUnobtrusiveTarget {
            standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
        }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        UpdateLogStore.shared.append("show update found: \(appcastItem.displayVersionString)")
        setStateAfterMinimumCheckDelay(.updateAvailable(.init(appcastItem: appcastItem, reply: reply)))
        if !hasUnobtrusiveTarget {
            standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // cmuxterm uses Sparkle's UI for release notes links instead.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // Release notes are handled via link buttons.
    }

    func showUpdateNotFoundWithError(_ error: any Error,
                                     acknowledgement: @escaping () -> Void) {
        UpdateLogStore.shared.append("show update not found: \(formatErrorForLog(error))")
        setStateAfterMinimumCheckDelay(.notFound(.init(acknowledgement: acknowledgement)))

        if !hasUnobtrusiveTarget {
            standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
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

        if !hasUnobtrusiveTarget {
            standard.showUpdaterError(error, acknowledgement: acknowledgement)
        } else {
            acknowledgement()
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        UpdateLogStore.shared.append("show download initiated")
        setState(.downloading(.init(
            cancel: cancellation,
            expectedLength: nil,
            progress: 0)))

        if !hasUnobtrusiveTarget {
            standard.showDownloadInitiated(cancellation: cancellation)
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        UpdateLogStore.shared.append("download expected length: \(expectedContentLength)")
        guard case let .downloading(downloading) = viewModel.state else {
            return
        }

        setState(.downloading(.init(
            cancel: downloading.cancel,
            expectedLength: expectedContentLength,
            progress: 0)))

        if !hasUnobtrusiveTarget {
            standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        UpdateLogStore.shared.append("download received data: \(length)")
        guard case let .downloading(downloading) = viewModel.state else {
            return
        }

        setState(.downloading(.init(
            cancel: downloading.cancel,
            expectedLength: downloading.expectedLength,
            progress: downloading.progress + length)))

        if !hasUnobtrusiveTarget {
            standard.showDownloadDidReceiveData(ofLength: length)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        UpdateLogStore.shared.append("show extraction started")
        setState(.extracting(.init(progress: 0)))

        if !hasUnobtrusiveTarget {
            standard.showDownloadDidStartExtractingUpdate()
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        UpdateLogStore.shared.append(String(format: "show extraction progress: %.2f", progress))
        setState(.extracting(.init(progress: progress)))

        if !hasUnobtrusiveTarget {
            standard.showExtractionReceivedProgress(progress)
        }
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        UpdateLogStore.shared.append("show ready to install")
        if !hasUnobtrusiveTarget {
            standard.showReady(toInstallAndRelaunch: reply)
        } else {
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

        if !hasUnobtrusiveTarget {
            standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        UpdateLogStore.shared.append("show update installed (relaunched=\(relaunched))")
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
        setState(.idle)
    }

    func showUpdateInFocus() {
        if !hasUnobtrusiveTarget {
            standard.showUpdateInFocus()
        }
    }

    func dismissUpdateInstallation() {
        UpdateLogStore.shared.append("dismiss update installation")
        if case .error = viewModel.state {
            UpdateLogStore.shared.append("dismiss update installation ignored (error visible)")
            standard.dismissUpdateInstallation()
            return
        }
        if case .notFound = viewModel.state {
            UpdateLogStore.shared.append("dismiss update installation ignored (notFound visible)")
            standard.dismissUpdateInstallation()
            return
        }
        if case .checking = viewModel.state {
            UpdateLogStore.shared.append("dismiss update installation ignored (checking)")
            standard.dismissUpdateInstallation()
            return
        }
        setState(.idle)
        standard.dismissUpdateInstallation()
    }

    private func beginChecking(cancel: @escaping () -> Void) {
        runOnMain { [weak self] in
            guard let self else { return }
            viewModel.overrideState = nil
            pendingCheckTransition?.cancel()
            pendingCheckTransition = nil
            checkTimeoutWorkItem?.cancel()
            checkTimeoutWorkItem = nil
            lastCheckStart = Date()
            applyState(.checking(.init(cancel: cancel)))
            scheduleCheckTimeout()
        }
    }

    private func setStateAfterMinimumCheckDelay(_ newState: UpdateState) {
        runOnMain { [weak self] in
            guard let self else { return }
            pendingCheckTransition?.cancel()
            pendingCheckTransition = nil
            checkTimeoutWorkItem?.cancel()
            checkTimeoutWorkItem = nil

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
                self.lastCheckStart = nil
                self.applyState(newState)
            }
            pendingCheckTransition = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func setState(_ newState: UpdateState) {
        runOnMain { [weak self] in
            guard let self else { return }
            pendingCheckTransition?.cancel()
            pendingCheckTransition = nil
            checkTimeoutWorkItem?.cancel()
            checkTimeoutWorkItem = nil
            lastCheckStart = nil
            applyState(newState)
        }
    }

    private func scheduleCheckTimeout() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard case .checking = self.viewModel.state else { return }
            self.setState(.notFound(.init(acknowledgement: {})))
        }
        checkTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + UpdateTiming.checkTimeoutDuration, execute: workItem)
    }

    private func applyState(_ newState: UpdateState) {
        viewModel.state = newState
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

    // MARK: No-Window Fallback

    /// True if there is a target that can render our unobtrusive update checker.
    var hasUnobtrusiveTarget: Bool {
        NSApp.windows.contains { $0.isVisible }
    }

    private func runOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
}
