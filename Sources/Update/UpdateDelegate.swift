import Sparkle
import Cocoa

enum UpdateChannelSettings {
    static let includeNightlyBuildsKey = "cmux.includeNightlyBuilds"
    static let defaultIncludeNightlyBuilds = false

    static let stableFeedURL = "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml"
    static let nightlyFeedURL = "https://github.com/manaflow-ai/cmux/releases/download/nightly/appcast.xml"

    static func resolvedFeedURLString(
        infoFeedURL: String?,
        defaults: UserDefaults = .standard
    ) -> (url: String, isNightly: Bool, usedFallback: Bool) {
        let stableURL = (infoFeedURL?.isEmpty == false) ? infoFeedURL! : stableFeedURL
        let includeNightlyBuilds = defaults.bool(forKey: includeNightlyBuildsKey)
        if includeNightlyBuilds {
            return (url: nightlyFeedURL, isNightly: true, usedFallback: false)
        }
        return (url: stableURL, isNightly: false, usedFallback: stableURL == stableFeedURL)
    }
}

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let override = env["CMUX_UI_TEST_FEED_URL"], !override.isEmpty {
            UpdateTestURLProtocol.registerIfNeeded()
            recordFeedURLString(override, usedFallback: false)
            return override
        }
#endif
        let infoURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let resolved = UpdateChannelSettings.resolvedFeedURLString(infoFeedURL: infoURL)
        UpdateLogStore.shared.append("update channel: \(resolved.isNightly ? "nightly" : "stable")")
        recordFeedURLString(resolved.url, usedFallback: resolved.usedFallback)
        return resolved.url
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when automatic download is enabled.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: immediateInstallHandler,
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            }
        ))
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        let count = appcast.items.count
        let firstVersion = appcast.items.first?.displayVersionString ?? ""
        if firstVersion.isEmpty {
            UpdateLogStore.shared.append("appcast loaded (items=\(count))")
        } else {
            UpdateLogStore.shared.append("appcast loaded (items=\(count), first=\(firstVersion))")
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let fileURL = item.fileURL?.absoluteString ?? ""
        if fileURL.isEmpty {
            UpdateLogStore.shared.append("valid update found: \(version)")
        } else {
            UpdateLogStore.shared.append("valid update found: \(version) (\(fileURL))")
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let nsError = error as NSError
        let reasonValue = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        let reason = reasonValue.map { SPUNoUpdateFoundReason(rawValue: OSStatus($0)) } ?? nil
        let reasonText = reason.map(describeNoUpdateFoundReason) ?? "unknown"
        let userInitiated = (nsError.userInfo[SPUNoUpdateFoundUserInitiatedKey] as? NSNumber)?.boolValue ?? false
        let latestItem = nsError.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        let latestVersion = latestItem?.displayVersionString ?? ""
        if latestVersion.isEmpty {
            UpdateLogStore.shared.append("no update found (reason=\(reasonText), userInitiated=\(userInitiated))")
        } else {
            UpdateLogStore.shared.append("no update found (reason=\(reasonText), userInitiated=\(userInitiated), latest=\(latestVersion))")
        }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        TerminalController.shared.stop()
        NSApp.invalidateRestorableState()
        for window in NSApp.windows {
            window.invalidateRestorableState()
        }
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
        return "unknown"
    }
}
