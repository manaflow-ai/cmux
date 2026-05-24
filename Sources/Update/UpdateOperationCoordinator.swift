import AppKit
import Foundation
import Sparkle

/// Owns active update UI state transitions on the main actor.
@MainActor
final class UpdateOperationCoordinator {
    let viewModel: UpdateViewModel

    private let minimumCheckDuration: TimeInterval
    private let checkTimeoutDuration: TimeInterval
    private let downloadStallTimeoutDuration: TimeInterval
    private let timeoutScheduler: any UpdateOperationTimeoutScheduling
    private var lastCheckStart: Date?
    private var pendingCheckTransition: (any UpdateOperationTimeoutCancellable)?
    private var timeout: (any UpdateOperationTimeoutCancellable)?
    private var operationID = 0

    init(
        viewModel: UpdateViewModel,
        minimumCheckDuration: TimeInterval = UpdateTiming.minimumCheckDisplayDuration,
        checkTimeoutDuration: TimeInterval = UpdateTiming.checkTimeoutDuration,
        downloadStallTimeoutDuration: TimeInterval = UpdateTiming.downloadStallTimeoutDuration,
        timeoutScheduler: any UpdateOperationTimeoutScheduling = UpdateOperationRunLoopTimeoutScheduler()
    ) {
        self.viewModel = viewModel
        self.minimumCheckDuration = minimumCheckDuration
        self.checkTimeoutDuration = checkTimeoutDuration
        self.downloadStallTimeoutDuration = downloadStallTimeoutDuration
        self.timeoutScheduler = timeoutScheduler
    }

    func beginChecking(cancel: @escaping () -> Void, retry: @escaping @MainActor () -> Void) {
        let id = nextOperationID()
        viewModel.overrideState = nil
        cancelPendingCheckTransition()
        cancelTimeout()
        lastCheckStart = Date()
        applyState(.checking(.init(cancel: cancel)))
        scheduleCheckingTimeout(operationID: id, cancel: cancel, retry: retry)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
    ) {
        guard case .checking = viewModel.state else {
            UpdateLogStore.shared.append("ignored update found outside checking")
            reply(.dismiss)
            return
        }
        setStateAfterMinimumCheckDelay(.updateAvailable(.init(appcastItem: appcastItem, reply: reply)))
    }

    func showUpdateNotFound(acknowledgement: @escaping () -> Void) {
        guard case .checking = viewModel.state else {
            UpdateLogStore.shared.append("ignored update not found outside checking")
            acknowledgement()
            return
        }
        setStateAfterMinimumCheckDelay(.notFound(.init(acknowledgement: acknowledgement)))
    }

    func showUpdaterError(
        _ error: any Error,
        retry: @escaping @MainActor () -> Void,
        dismiss: @escaping @MainActor () -> Void,
        technicalDetails: String?,
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

    func showDownloadInitiated(cancellation: @escaping () -> Void, retry: @escaping @MainActor () -> Void) {
        let id = nextOperationID()
        setState(.downloading(.init(
            cancel: cancellation,
            expectedLength: nil,
            progress: 0
        )))
        scheduleDownloadStallTimeout(operationID: id, cancel: cancellation, retry: retry)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard case let .downloading(downloading) = viewModel.state else {
            return
        }

        applyState(.downloading(.init(
            cancel: downloading.cancel,
            expectedLength: expectedContentLength,
            progress: 0
        )))
        scheduleDownloadStallTimeout(
            operationID: operationID,
            cancel: downloading.cancel,
            retry: retryUpdateCheck
        )
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard case let .downloading(downloading) = viewModel.state else {
            return
        }

        applyState(.downloading(.init(
            cancel: downloading.cancel,
            expectedLength: downloading.expectedLength,
            progress: downloading.progress + length
        )))
        scheduleDownloadStallTimeout(
            operationID: operationID,
            cancel: downloading.cancel,
            retry: retryUpdateCheck
        )
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelTimeout()
        setState(.extracting(.init(progress: 0)))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        setState(.extracting(.init(progress: progress)))
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        switch viewModel.state {
        case .updateAvailable, .downloading, .extracting, .installing:
            reply(.install)
        default:
            UpdateLogStore.shared.append("ignored ready to install outside active update")
            reply(.dismiss)
        }
    }

    func showInstallingUpdate(retryTerminatingApplication: @escaping () -> Void) {
        switch viewModel.state {
        case .updateAvailable, .downloading, .extracting, .installing:
            break
        default:
            UpdateLogStore.shared.append("ignored installing update outside active update")
            return
        }
        setState(.installing(.init(
            retryTerminatingApplication: retryTerminatingApplication,
            dismiss: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.viewModel.state = .idle
                }
            }
        )))
    }

    func showUpdateInstalledAndRelaunched(acknowledgement: @escaping () -> Void) {
        setState(.idle)
        acknowledgement()
    }

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

    func recordDetectedUpdate(_ appcastItem: SUAppcastItem) {
        viewModel.recordDetectedUpdate(appcastItem)
    }

    func dismissDetectedAvailableUpdate() {
        viewModel.dismissDetectedAvailableUpdate()
    }

    func clearDetectedUpdate() {
        viewModel.clearDetectedUpdate()
    }

    private func setStateAfterMinimumCheckDelay(_ newState: UpdateState) {
        cancelPendingCheckTransition()
        cancelTimeout()

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
        pendingCheckTransition = timeoutScheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            guard case .checking = self.viewModel.state else { return }
            self.lastCheckStart = nil
            self.applyState(newState)
        }
    }

    private func setState(_ newState: UpdateState) {
        cancelPendingCheckTransition()
        cancelTimeout()
        lastCheckStart = nil
        applyState(newState)
    }

    private func scheduleCheckingTimeout(
        operationID id: Int,
        cancel: @escaping () -> Void,
        retry: @escaping @MainActor () -> Void
    ) {
        guard checkTimeoutDuration > 0 else { return }
        timeout = timeoutScheduler.schedule(after: checkTimeoutDuration) { [weak self] in
            guard let self else { return }
            guard self.operationID == id else { return }
            guard case .checking = self.viewModel.state else { return }
            UpdateLogStore.shared.append("checking timed out after \(self.checkTimeoutDuration)s")
            cancel()
            self.showTimeoutError(
                UpdateOperationTimeoutError.checking(after: self.checkTimeoutDuration),
                retry: retry
            )
        }
    }

    private func scheduleDownloadStallTimeout(
        operationID id: Int,
        cancel: @escaping () -> Void,
        retry: @escaping @MainActor () -> Void
    ) {
        guard downloadStallTimeoutDuration > 0 else { return }
        cancelTimeout()
        timeout = timeoutScheduler.schedule(after: downloadStallTimeoutDuration) { [weak self] in
            guard let self else { return }
            guard self.operationID == id else { return }
            guard case .downloading = self.viewModel.state else { return }
            UpdateLogStore.shared.append("download stalled for \(self.downloadStallTimeoutDuration)s")
            cancel()
            self.showTimeoutError(
                UpdateOperationTimeoutError.downloading(after: self.downloadStallTimeoutDuration),
                retry: retry
            )
        }
    }

    private func showTimeoutError(_ error: NSError, retry: @escaping @MainActor () -> Void) {
        cancelPendingCheckTransition()
        cancelTimeout()
        lastCheckStart = nil
        applyState(.error(.init(
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
                    self?.viewModel.state = .idle
                }
            },
            technicalDetails: nil,
            feedURLString: nil
        )))
    }

    private func cancelPendingCheckTransition() {
        pendingCheckTransition?.cancel()
        pendingCheckTransition = nil
    }

    private func cancelTimeout() {
        timeout?.cancel()
        timeout = nil
    }

    private func nextOperationID() -> Int {
        operationID += 1
        return operationID
    }

    private func retryUpdateCheck() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.checkForUpdates(nil)
    }

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
