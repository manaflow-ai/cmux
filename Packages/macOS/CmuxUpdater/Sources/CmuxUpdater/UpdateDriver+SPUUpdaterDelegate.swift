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
        let resolved = UpdateFeedResolver().resolve(infoFeedURL: infoFeedURLProvider())
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
        model.clearDetectedUpdate()
        model.setState(.installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: immediateInstallHandler,
            dismiss: { [weak self] in
                self?.model.setState(.idle)
            }
        )))
        return true
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
            // gates every known path (automatic checks, the launch probe, and manual
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
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        handleDidNotFindUpdate(error)
    }

    /// Handles Sparkle's no-update delegate result without requiring a live `SPUUpdater` in tests.
    func handleDidNotFindUpdate(_ error: any Error) {
        // Delegate callbacks also arrive for automatic/informational probes. They may clear the
        // passive detection cache, but must never answer or erase a foreground Sparkle prompt.
        model.clearDetectedUpdate()
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

    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        handleDidFinishUpdateCycle(updateCheck, error: error)
    }

    /// Forwards Sparkle's authoritative session-finished signal to the lifecycle owner.
    /// Extracted so the replacement-check race is testable without constructing `SPUUpdater`.
    func handleDidFinishUpdateCycle(_ updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let errorText = error.map(formatErrorForLog) ?? "none"
        log.append("update cycle finished (check=\(updateCheck.rawValue), error=\(errorText))")
        eventDelegate?.updateDriverDidFinishCycle(updateCheck, error: error.map { $0 as NSError })
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
    case .hardwareDoesNotSupportARM64:
        return "hardwareDoesNotSupportARM64"
    @unknown default:
        // Preserve forward compatibility when a future Sparkle release adds another reason.
        return "unknown"
    }
}
