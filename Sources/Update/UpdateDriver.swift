import Cocoa
import Sparkle

/// Owns active update UI state transitions on the main actor.
final class UpdateOperationCoordinator {
    let viewModel: UpdateViewModel

    private let minimumCheckDuration: TimeInterval
    private var lastCheckStart: Date?
    private var pendingCheckTransition: DispatchWorkItem?
    private var checkTimeoutWorkItem: DispatchWorkItem?

    init(
        viewModel: UpdateViewModel,
        minimumCheckDuration: TimeInterval = UpdateTiming.minimumCheckDisplayDuration
    ) {
        self.viewModel = viewModel
        self.minimumCheckDuration = minimumCheckDuration
    }

    @MainActor
    func beginChecking(cancel: @escaping () -> Void) {
        viewModel.overrideState = nil
        cancelPendingCheckTransition()
        cancelCheckTimeout()
        lastCheckStart = Date()
        applyState(.checking(.init(cancel: cancel)))
        scheduleCheckTimeout()
    }

    @MainActor
    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
    ) {
        setStateAfterMinimumCheckDelay(.updateAvailable(.init(appcastItem: appcastItem, reply: reply)))
    }

    @MainActor
    func showUpdateNotFound(acknowledgement: @escaping () -> Void) {
        setStateAfterMinimumCheckDelay(.notFound(.init(acknowledgement: acknowledgement)))
    }

    @MainActor
    func showUpdaterError(
        _ error: any Error,
        retry: @escaping @MainActor () -> Void,
        dismiss: @escaping @MainActor () -> Void,
        technicalDetails: String,
        feedURLString: String?
    ) {
        setState(.error(.init(
            error: error,
            retry: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.viewModel.state = .idle
                    retry()
                }
            },
            dismiss: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.viewModel.state = .idle
                    dismiss()
                }
            },
            technicalDetails: technicalDetails,
            feedURLString: feedURLString
        )))
    }

    @MainActor
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        setState(.downloading(.init(
            cancel: cancellation,
            expectedLength: nil,
            progress: 0
        )))
    }

    @MainActor
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard case let .downloading(downloading) = viewModel.state else {
            return
        }

        setState(.downloading(.init(
            cancel: downloading.cancel,
            expectedLength: expectedContentLength,
            progress: 0
        )))
    }

    @MainActor
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard case let .downloading(downloading) = viewModel.state else {
            return
        }

        setState(.downloading(.init(
            cancel: downloading.cancel,
            expectedLength: downloading.expectedLength,
            progress: downloading.progress + length
        )))
    }

    @MainActor
    func showDownloadDidStartExtractingUpdate() {
        setState(.extracting(.init(progress: 0)))
    }

    @MainActor
    func showExtractionReceivedProgress(_ progress: Double) {
        setState(.extracting(.init(progress: progress)))
    }

    @MainActor
    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        reply(.install)
    }

    @MainActor
    func showInstallingUpdate(retryTerminatingApplication: @escaping () -> Void) {
        setState(.installing(.init(
            retryTerminatingApplication: retryTerminatingApplication,
            dismiss: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.viewModel.state = .idle
                }
            }
        )))
    }

    @MainActor
    func showUpdateInstalledAndRelaunched(acknowledgement: @escaping () -> Void) {
        setState(.idle)
        acknowledgement()
    }

    @MainActor
    func dismissUpdateInstallation() {
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

    @MainActor
    func showWillInstallUpdateOnQuit(
        immediateInstallHandler: @escaping () -> Void
    ) {
        viewModel.clearDetectedUpdate()
        viewModel.state = .installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: immediateInstallHandler,
            dismiss: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.viewModel.state = .idle
                }
            }
        ))
    }

    @MainActor
    func recordDetectedUpdate(_ appcastItem: SUAppcastItem) {
        viewModel.recordDetectedUpdate(appcastItem)
    }

    @MainActor
    func dismissDetectedAvailableUpdate() {
        viewModel.dismissDetectedAvailableUpdate()
    }

    @MainActor
    func clearDetectedUpdate() {
        viewModel.clearDetectedUpdate()
    }

    @MainActor
    private func setStateAfterMinimumCheckDelay(_ newState: UpdateState) {
        cancelPendingCheckTransition()
        cancelCheckTimeout()

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
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard case .checking = self.viewModel.state else { return }
                self.lastCheckStart = nil
                self.applyState(newState)
            }
        }
        pendingCheckTransition = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    @MainActor
    private func setState(_ newState: UpdateState) {
        cancelPendingCheckTransition()
        cancelCheckTimeout()
        lastCheckStart = nil
        applyState(newState)
    }

    @MainActor
    private func scheduleCheckTimeout() {
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard case .checking = self.viewModel.state else { return }
                self.setState(.notFound(.init(acknowledgement: {})))
            }
        }
        checkTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + UpdateTiming.checkTimeoutDuration, execute: workItem)
    }

    @MainActor
    private func cancelPendingCheckTransition() {
        pendingCheckTransition?.cancel()
        pendingCheckTransition = nil
    }

    @MainActor
    private func cancelCheckTimeout() {
        checkTimeoutWorkItem?.cancel()
        checkTimeoutWorkItem = nil
    }

    @MainActor
    private func applyState(_ newState: UpdateState) {
        viewModel.applyDriverState(newState)
        UpdateLogStore.shared.append("state -> \(describe(newState))")
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

/// SPUUserDriver that adapts Sparkle callbacks into custom update UI operations.
class UpdateDriver: NSObject, SPUUserDriver {
    let viewModel: UpdateViewModel
    private let operationCoordinator: UpdateOperationCoordinator
    private var lastFeedURLString: String?

    init(viewModel: UpdateViewModel, hostBundle _: Bundle) {
        self.viewModel = viewModel
        self.operationCoordinator = UpdateOperationCoordinator(viewModel: viewModel)
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
        runOnCoordinator { coordinator in
            coordinator.beginChecking(cancel: cancellation)
        }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state _: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        UpdateLogStore.shared.append("show update found: \(appcastItem.displayVersionString)")
        runOnCoordinator { coordinator in
            coordinator.showUpdateFound(with: appcastItem, reply: reply)
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
        runOnCoordinator { coordinator in
            coordinator.showUpdateNotFound(acknowledgement: acknowledgement)
        }
    }

    func showUpdaterError(_ error: any Error,
                          acknowledgement: @escaping () -> Void) {
        let details = formatErrorForLog(error)
        let feedURLString = lastFeedURLString
        UpdateLogStore.shared.append("show updater error: \(details)")
        runOnCoordinator { coordinator in
            coordinator.showUpdaterError(
                error,
                retry: {
                    guard let delegate = NSApp.delegate as? AppDelegate else { return }
                    delegate.checkForUpdates(nil)
                },
                dismiss: {},
                technicalDetails: details,
                feedURLString: feedURLString
            )
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        UpdateLogStore.shared.append("show download initiated")
        runOnCoordinator { coordinator in
            coordinator.showDownloadInitiated(cancellation: cancellation)
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        UpdateLogStore.shared.append("download expected length: \(expectedContentLength)")
        runOnCoordinator { coordinator in
            coordinator.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        UpdateLogStore.shared.append("download received data: \(length)")
        runOnCoordinator { coordinator in
            coordinator.showDownloadDidReceiveData(ofLength: length)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        UpdateLogStore.shared.append("show extraction started")
        runOnCoordinator { coordinator in
            coordinator.showDownloadDidStartExtractingUpdate()
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        UpdateLogStore.shared.append(String(format: "show extraction progress: %.2f", progress))
        runOnCoordinator { coordinator in
            coordinator.showExtractionReceivedProgress(progress)
        }
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        UpdateLogStore.shared.append("show ready to install")
        runOnCoordinator { coordinator in
            coordinator.showReady(toInstallAndRelaunch: reply)
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        UpdateLogStore.shared.append("show installing update")
        runOnCoordinator { coordinator in
            coordinator.showInstallingUpdate(retryTerminatingApplication: retryTerminatingApplication)
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        UpdateLogStore.shared.append("show update installed (relaunched=\(relaunched))")
        runOnCoordinator { coordinator in
            coordinator.showUpdateInstalledAndRelaunched(acknowledgement: acknowledgement)
        }
    }

    func showUpdateInFocus() {
        // No-op; cmux never shows Sparkle dialogs.
    }

    func dismissUpdateInstallation() {
        UpdateLogStore.shared.append("dismiss update installation")
        runOnCoordinator { coordinator in
            coordinator.dismissUpdateInstallation()
        }
    }

    func showWillInstallUpdateOnQuit(
        immediateInstallHandler: @escaping () -> Void
    ) {
        runOnCoordinator { coordinator in
            coordinator.showWillInstallUpdateOnQuit(immediateInstallHandler: immediateInstallHandler)
        }
    }

    func recordDetectedUpdate(_ appcastItem: SUAppcastItem) {
        runOnCoordinator { coordinator in
            coordinator.recordDetectedUpdate(appcastItem)
        }
    }

    func dismissDetectedAvailableUpdate() {
        runOnCoordinator { coordinator in
            coordinator.dismissDetectedAvailableUpdate()
        }
    }

    func clearDetectedUpdate() {
        runOnCoordinator { coordinator in
            coordinator.clearDetectedUpdate()
        }
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

    private func runOnCoordinator(_ action: @escaping @MainActor (UpdateOperationCoordinator) -> Void) {
        let operationCoordinator = operationCoordinator
        Task { @MainActor in
            action(operationCoordinator)
        }
    }
}
