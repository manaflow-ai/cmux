import Foundation

/// The driver's answers to Sparkle's `SPUUpdaterDelegate` callbacks, which
/// ``SparkleDriverBridge`` forwards with cmux values. Each is callable directly, so tests drive
/// them without a live `SPUUpdater`.
extension UpdateDriver {
    /// The feed URL Sparkle reads for the next check (`feedURLString(for:)`).
    func feedURLStringForCheck() -> String? {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let override = env["CMUX_UI_TEST_FEED_URL"], !override.isEmpty {
            UpdateTestURLProtocol.registerIfNeeded()
            recordFeedURLString(override, usedFallback: false)
            return override
        }
#endif
        let url = resolvedFeedURL()
        recordFeedURLString(url, usedFallback: feedOverride == nil && UpdateFeedResolver().resolve(infoFeedURL: infoFeedURLProvider()).usedFallback)
        return url
    }

    /// The feed every check reads: a test feed override, else the feed baked into Info.plist
    /// (stable releases use the stable appcast; cmux NIGHTLY and RC have their channel appcast
    /// URL injected by CI).
    func resolvedFeedURL() -> String {
        if let feedOverride {
            log.append("update channel: test feed \(feedOverride)")
            return feedOverride
        }
        let resolved = UpdateFeedResolver().resolve(infoFeedURL: infoFeedURLProvider())
        log.append("update channel: \(resolved.channel.rawValue)")
        return resolved.url
    }

    /// cmux-next appcast items carry a `sparkle:channel` per release ring; only a build whose
    /// baked feed is the cmux-next feed accepts them, and only the tags of its ring and the
    /// slower ones. Every other build allows no extra channel, so it ignores those items even
    /// if a wrong feed URL served them.
    func allowedChannels() -> Set<String> {
        UpdateFeedResolver().resolve(infoFeedURL: infoFeedURLProvider()).channel.allowedSparkleChannels(ring: ring)
    }

    func handleWillInstallUpdate(_ item: UpdateAppcastItem) {
        log.append("will install \(item.versionString)")
        actionDelegate?.updaterWillInstallUpdate(build: item.versionString)
    }

    func handleWillScheduleUpdateCheck(afterDelay delay: TimeInterval) {
        log.append("next update check scheduled in \(Int(delay.rounded()))s")
    }

    func handleWillNotScheduleUpdateCheck() {
        log.append("automatic update checks disabled; no scheduled check")
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when automatic download is enabled.
    func handleWillInstallUpdateOnQuit(_ item: UpdateAppcastItem, immediateInstallHandler: @escaping () -> Void) -> Bool {
        log.append("silent install staged \(item.versionString) (\(item.displayVersionString))")
        model.clearDetectedUpdate()
        // Sparkle's own silent install: only a click starts it, never the idle policy.
        relaunchIsAutomatic = false
        quitInstallItem = item
        model.setState(.installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: immediateInstallHandler,
            dismiss: { [weak self] in
                self?.model.setState(.idle)
            }
        )))
        return true
    }

    func handleDidFinishLoadingAppcast(itemCount count: Int, firstDisplayVersion firstVersion: String) {
        if firstVersion.isEmpty {
            log.append("appcast loaded (items=\(count))")
        } else {
            log.append("appcast loaded (items=\(count), first=\(firstVersion))")
        }
    }

    /// Records a background-detected available update — unless this is a DEV/staging build, in
    /// which case any detected update is cleared so the public appcast's pill never appears.
    func handleDidFindValidUpdate(_ item: UpdateAppcastItem) {
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

    /// Handles Sparkle's no-update delegate result.
    func handleDidNotFindUpdate(_ error: any Error) {
        // Delegate callbacks also arrive for automatic/informational probes. They may clear the
        // passive detection cache, but must never answer or erase a foreground Sparkle prompt.
        model.clearDetectedUpdate()
        let result = SparkleNoUpdateFound(error)
        if result.latestDisplayVersion.isEmpty {
            log.append("no update found (reason=\(result.reason), userInitiated=\(result.userInitiated))")
        } else {
            log.append("no update found (reason=\(result.reason), userInitiated=\(result.userInitiated), latest=\(result.latestDisplayVersion))")
        }
    }

    /// Forwards Sparkle's authoritative session-finished signal to the lifecycle owner.
    func handleDidFinishUpdateCycle(_ updateCheck: UpdateCheckKind, error: (any Error)?) {
        let errorText = error.map(formatErrorForLog) ?? "none"
        log.append("update cycle finished (check=\(updateCheck.rawValue), error=\(errorText))")
        relaunchGate.cancel()
        endAutomaticInstallHold()
        relaunchIsAutomatic = false
        eventDelegate?.updateDriverDidFinishCycle(updateCheck, error: error.map { $0 as NSError })
    }

    /// The person answered a Sparkle prompt (`updater(_:userDidMake:forUpdate:state:)`).
    func handleUserDidMakeChoice() {
        model.clearDetectedUpdate()
    }

    func handleWillRelaunchApplication() {
        actionDelegate?.updaterWillRelaunchApplication()
    }
}
