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

    static func shouldOfferStableDowngrade(
        includeNightlyBuilds: Bool,
        currentShortVersion: String?
    ) -> Bool {
        guard !includeNightlyBuilds else { return false }
        guard let currentShortVersion, !currentShortVersion.isEmpty else { return false }
        return currentShortVersion.contains("-nightly")
    }

    static func shouldOfferStableDowngrade(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> Bool {
        shouldOfferStableDowngrade(
            includeNightlyBuilds: defaults.bool(forKey: includeNightlyBuildsKey),
            currentShortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
    }

    struct SemanticVersion: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
    }

    static func semanticVersion(from versionString: String?) -> SemanticVersion? {
        guard let versionString, !versionString.isEmpty else { return nil }
        guard let range = versionString.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else {
            return nil
        }
        let components = versionString[range].split(separator: ".")
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]) else {
            return nil
        }
        return SemanticVersion(major: major, minor: minor, patch: patch)
    }

    static func shouldOfferNightlyCandidate(
        currentShortVersion: String?,
        candidateDisplayVersion: String?
    ) -> Bool {
        guard let currentSemanticVersion = semanticVersion(from: currentShortVersion) else { return true }
        guard let candidateSemanticVersion = semanticVersion(from: candidateDisplayVersion) else { return false }
        return candidateSemanticVersion >= currentSemanticVersion
    }

    static func shouldOfferStableCandidate(
        currentBuildVersion: String?,
        candidateBuildVersion: String?
    ) -> Bool {
        guard let currentBuildVersion, !currentBuildVersion.isEmpty else { return true }
        guard let candidateBuildVersion, !candidateBuildVersion.isEmpty else { return false }
        return SUStandardVersionComparator.default.compareVersion(currentBuildVersion, toVersion: candidateBuildVersion) == .orderedAscending
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

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        let defaults = UserDefaults.standard
        let includeNightlyBuilds = defaults.bool(forKey: UpdateChannelSettings.includeNightlyBuildsKey)
        let currentShortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let currentBuildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        if UpdateChannelSettings.shouldOfferStableDowngrade(
            includeNightlyBuilds: includeNightlyBuilds,
            currentShortVersion: currentShortVersion
        ) {
            guard let latestStableItem = appcast.items.first else { return nil }
            guard UpdateChannelSettings.shouldOfferStableCandidate(
                currentBuildVersion: currentBuildVersion,
                candidateBuildVersion: latestStableItem.versionString
            ) else {
                let stableVersion = latestStableItem.displayVersionString
                if stableVersion.isEmpty {
                    UpdateLogStore.shared.append("stable channel override: latest stable build is not newer than current nightly build; not offering impossible downgrade")
                } else {
                    UpdateLogStore.shared.append("stable channel override: \(stableVersion) is not newer than current nightly build; not offering impossible downgrade")
                }
                return SUAppcastItem.empty()
            }
            let version = latestStableItem.displayVersionString
            if version.isEmpty {
                UpdateLogStore.shared.append("stable channel override: selecting latest stable item")
            } else {
                UpdateLogStore.shared.append("stable channel override: selecting \(version) so nightly users can return to stable")
            }
            return latestStableItem
        }

        guard includeNightlyBuilds else { return nil }
        let currentSemanticVersion = UpdateChannelSettings.semanticVersion(from: currentShortVersion)
        if let selectedNightlyItem = appcast.items.first(where: { item in
            UpdateChannelSettings.shouldOfferNightlyCandidate(
                currentShortVersion: currentShortVersion,
                candidateDisplayVersion: item.displayVersionString
            )
        }) {
            if let firstItem = appcast.items.first, selectedNightlyItem !== firstItem {
                let version = selectedNightlyItem.displayVersionString
                if version.isEmpty {
                    UpdateLogStore.shared.append("nightly channel override: skipped older nightly candidates")
                } else {
                    UpdateLogStore.shared.append("nightly channel override: selecting \(version) (skipped older nightly candidates)")
                }
            }
            return selectedNightlyItem
        }

        if currentSemanticVersion != nil {
            UpdateLogStore.shared.append("nightly channel override: no nightly semantic version >= current build")
            return SUAppcastItem.empty()
        }
        return nil
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
