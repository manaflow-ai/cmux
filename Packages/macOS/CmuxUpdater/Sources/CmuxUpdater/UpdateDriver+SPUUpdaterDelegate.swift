import Foundation
@preconcurrency import Sparkle

extension UpdateDriver: @preconcurrency SPUUpdaterDelegate {
    func updaterShouldPromptForPermissionToCheck(forUpdates _: SPUUpdater) -> Bool {
        false
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let override = env["CMUX_UI_TEST_FEED_URL"], !override.isEmpty {
            UpdateTestURLProtocol.registerIfNeeded()
            recordFeedURLString(override, usedFallback: false)
            return override
        }
#endif
        // The feed URL is baked into Info.plist at build time:
        // - Stable releases use the stable appcast URL
        // - cmux NIGHTLY has the nightly appcast URL injected by CI
        let infoFeedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let resolved = UpdateFeedResolver().resolve(infoFeedURL: infoFeedURL)
        log.append("update channel: \(resolved.isNightly ? "nightly" : "stable")")
        recordFeedURLString(resolved.url, usedFallback: resolved.usedFallback)
        return resolved.url
    }

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        log.append("next update check scheduled in \(Int(delay.rounded()))s")
    }

    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        log.append("automatic update checks disabled; no scheduled check")
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when automatic download is enabled.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = UpdateStateModel.normalizedDetectedUpdateVersion(from: item.displayVersionString)
        log.append("update staged for install on quit: \(version ?? "<unknown version>")")
        model.clearDetectedUpdate()
        model.setState(.installing(.init(
            isAutoUpdate: true,
            stagedVersion: version,
            retryTerminatingApplication: immediateInstallHandler,
            dismiss: { [weak self] in
                self?.model.setState(.idle)
            }
        )))
        return true
    }

    /// Called when an update session aborts. Background auto-download failures surface here
    /// (not necessarily through the user driver's `showUpdaterError`), so this is where the
    /// silent-retry hook fires for sessions the user never initiated (#5632).
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        // SUNoUpdateError (1001) flows through here for every no-update session end; only log
        // genuinely unexpected aborts to keep the update log readable.
        guard nsError.domain != SUSparkleErrorDomain || nsError.code != 1001 else { return }
        log.append("update session aborted: \(formatErrorForLog(error))")
        if !hasUserInitiatedSession {
            onBackgroundSessionError?(error)
        }
    }

    /// Sparkle's session-teardown signal: fires when an update cycle finishes, whether it
    /// succeeded, found nothing, or aborted. Ends any user-initiated session (so a later
    /// background failure is correctly suppressed) and lets the controller run work that must
    /// wait for the session to be over (the silent-download kick).
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        hasUserInitiatedSession = false
        onUpdateSessionFinished?()
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        let count = appcast.items.count
        let firstVersion = appcast.items.first?.displayVersionString ?? ""
        if firstVersion.isEmpty {
            log.append("appcast loaded (items=\(count))")
        } else {
            log.append("appcast loaded (items=\(count), first=\(firstVersion))")
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        handleDidFindValidUpdate(item)
    }

    /// Records a background-detected available update — unless this is a DEV/staging build, in
    /// which case any detected update is cleared so the public appcast's pill never appears.
    ///
    /// Extracted from the ``SPUUpdaterDelegate`` callback (which carries an `SPUUpdater` that is
    /// awkward to construct) so the dev/staging gate is unit-testable directly from an
    /// ``UpdateStateModel`` and an `SUAppcastItem`.
    func handleDidFindValidUpdate(_ item: SUAppcastItem) {
        if isDevLikeBundle {
            // DEV/staging builds are not on the public release train. ``UpdateController`` already
            // gates every known path (automatic checks, the launch/background probe, and manual
            // checks), so this is the last-line defense: if any update is ever found for one of
            // these builds, clear it rather than surfacing the pill (#6292).
            model.clearDetectedUpdate()
            log.append("ignoring update for dev/staging build: \(item.displayVersionString)")
            return
        }
        model.recordDetectedUpdate(item)
        let version = item.displayVersionString
        let fileURL = item.fileURL?.absoluteString ?? ""
        if fileURL.isEmpty {
            log.append("valid update found: \(version)")
        } else {
            log.append("valid update found: \(version) (\(fileURL))")
        }
        // Kick the silent download now instead of waiting for Sparkle's next scheduled check,
        // so the "update ready" toast appears shortly after a release is detected.
        onBackgroundUpdateDetected?()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        model.dismissDetectedAvailableUpdate()
        let nsError = error as NSError
        let reasonValue = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        let reason = reasonValue.map { SPUNoUpdateFoundReason(rawValue: OSStatus($0)) } ?? nil
        let reasonText = reason.map(describeNoUpdateFoundReason) ?? "unknown"
        let userInitiated = (nsError.userInfo[SPUNoUpdateFoundUserInitiatedKey] as? NSNumber)?.boolValue ?? false
        let latestItem = nsError.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        let latestVersion = latestItem?.displayVersionString ?? ""
        if latestVersion.isEmpty {
            log.append("no update found (reason=\(reasonText), userInitiated=\(userInitiated))")
        } else {
            log.append("no update found (reason=\(reasonText), userInitiated=\(userInitiated), latest=\(latestVersion))")
        }
    }

    func updater(_ updater: SPUUpdater, userDidMake _: SPUUserUpdateChoice, forUpdate _: SUAppcastItem, state _: SPUUserUpdateState) {
        model.clearDetectedUpdate()
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        actionDelegate?.updaterWillRelaunchApplication()
    }
}

private func describeNoUpdateFoundReason(_ reason: SPUNoUpdateFoundReason) -> String {
    switch reason {
    case .unknown:
        return "unknown"
    case .onLatestVersion:
        return "onLatestVersion"
    case .onNewerThanLatestVersion:
        return "onNewerThanLatestVersion"
    case .systemIsTooOld:
        return "systemIsTooOld"
    case .systemIsTooNew:
        return "systemIsTooNew"
    @unknown default:
        // Newer Sparkle adds cases like `.hardwareDoesNotSupportARM64`; handled here so the
        // code compiles against the app's pinned (older) Sparkle and newer SwiftPM resolutions.
        return "unknown"
    }
}
