import Cocoa
import Sparkle

/// SPUUserDriver that adapts Sparkle callbacks into custom update UI operations.
class UpdateDriver: NSObject, SPUUserDriver {
    let viewModel: UpdateViewModel
    private let operationCoordinator: UpdateOperationCoordinator
    private var lastFeedURLString: String?

    init(viewModel: UpdateViewModel, hostBundle _: Bundle) {
        self.viewModel = viewModel
        self.operationCoordinator = MainActor.assumeIsolated {
            UpdateOperationCoordinator(viewModel: viewModel)
        }
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
            coordinator.beginChecking(
                cancel: cancellation,
                retry: {
                    guard let delegate = NSApp.delegate as? AppDelegate else { return }
                    delegate.checkForUpdates(nil)
                }
            )
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
        let displayDetails = formatErrorForDisplay(error)
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
                technicalDetails: displayDetails,
                feedURLString: feedURLString
            )
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        UpdateLogStore.shared.append("show download initiated")
        runOnCoordinator { coordinator in
            coordinator.showDownloadInitiated(
                cancellation: cancellation,
                retry: {
                    guard let delegate = NSApp.delegate as? AppDelegate else { return }
                    delegate.checkForUpdates(nil)
                }
            )
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

    private func formatErrorForDisplay(_ error: Error) -> String {
        let nsError = error as NSError
        var parts: [String] = ["code=\(nsError.code)"]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlyingCode=\(underlying.code)")
        }
        if nsError.userInfo[NSURLErrorFailingURLErrorKey] != nil ||
            nsError.userInfo[NSURLErrorFailingURLStringErrorKey] != nil {
            parts.append("networkContext=available")
        }
        if lastFeedURLString != nil {
            parts.append("feed=configured")
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
