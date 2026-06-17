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
        // Backstop for DEV/staging builds: veto Sparkle's silent install-on-quit so the public
        // release can never be installed over a locally-built app.
        //
        // Sparkle's contract: returning YES means the delegate OWNS the installation, NO hands
        // responsibility back to Sparkle (which then installs on quit). So to actually suppress
        // the install we must return `true` and simply drop the update on the floor — never
        // invoking `immediateInstallHandler` and never resuming it — instead of returning `false`.
        if suppressesPublicUpdates {
            log.append("vetoing silent install-on-quit on dev/staging build: \(item.displayVersionString)")
            model.clearDetectedUpdate()
            model.setState(.idle)
            return true
        }
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
        // DEV / staging builds are off the public release train. If Sparkle still surfaces an
        // update here (e.g. a manual "Check for Updates", or a probe that started before the
        // launch gate landed), clear it instead of recording so the pill never appears.
        if suppressesPublicUpdates {
            model.clearDetectedUpdate()
            log.append("ignoring found update on dev/staging build: \(item.displayVersionString)")
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
