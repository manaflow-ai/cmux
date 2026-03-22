import Sparkle
import Cocoa
import Combine
import ObjectiveC.runtime
import SwiftUI

enum UpdateSettings {
    static let automaticChecksKey = "SUEnableAutomaticChecks"
    static let automaticallyUpdateKey = "SUAutomaticallyUpdate"
    static let scheduledCheckIntervalKey = "SUScheduledCheckInterval"
    static let sendProfileInfoKey = "SUSendProfileInfo"
    static let migrationKey = "cmux.sparkle.automaticChecksMigration.v2"
    static let previousDefaultScheduledCheckInterval: TimeInterval = 60 * 60 * 24
    static let scheduledCheckInterval: TimeInterval = 60 * 60

    static func apply(to defaults: UserDefaults) {
        defaults.register(defaults: [
            automaticChecksKey: true,
            automaticallyUpdateKey: false,
            scheduledCheckIntervalKey: scheduledCheckInterval,
            sendProfileInfoKey: false,
        ])

        guard !defaults.bool(forKey: migrationKey) else { return }

        // Repair older installs that may have ended up with automatic checks disabled
        // before the updater defaults were embedded in Info.plist.
        defaults.set(true, forKey: automaticChecksKey)

        if let interval = defaults.object(forKey: scheduledCheckIntervalKey) as? NSNumber {
            let currentInterval = interval.doubleValue
            if currentInterval <= 0 ||
                abs(currentInterval - previousDefaultScheduledCheckInterval) < 1 {
                defaults.set(scheduledCheckInterval, forKey: scheduledCheckIntervalKey)
            }
        } else {
            defaults.set(scheduledCheckInterval, forKey: scheduledCheckIntervalKey)
        }

        if defaults.object(forKey: automaticallyUpdateKey) == nil {
            defaults.set(false, forKey: automaticallyUpdateKey)
        }
        if defaults.object(forKey: sendProfileInfoKey) == nil {
            defaults.set(false, forKey: sendProfileInfoKey)
        }

        defaults.set(true, forKey: migrationKey)
    }
}

/// Controller for managing Sparkle updates in cmux.
class UpdateController {
    private(set) var updater: SPUUpdater
    private let userDriver: UpdateDriver
    private var installCancellable: AnyCancellable?
    private var attemptInstallCancellable: AnyCancellable?
    private var didObserveAttemptUpdateProgress: Bool = false
    private var noUpdateDismissCancellable: AnyCancellable?
    private var noUpdateDismissWorkItem: DispatchWorkItem?
    private var readyCheckWorkItem: DispatchWorkItem?
    private var backgroundProbeTimer: Timer?
    private var didStartUpdater: Bool = false
    private var latestItemProbe: UpdateLatestItemProbe?
    private var latestItemProbeQueuedFollowUp: (() -> Void)?
    private var isShowingLatestItemProbeCheckingState: Bool = false
    private let readyRetryDelay: TimeInterval = 0.25
    private let readyRetryCount: Int = 20
    private let backgroundProbeInterval: TimeInterval = UpdateSettings.scheduledCheckInterval
#if DEBUG
    private var debugDeferredUpdateCandidate: DeferredUpdateCandidate?
#endif

    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }

    /// True if we're force-installing an update.
    var isInstalling: Bool {
        installCancellable != nil
    }

    init() {
        let defaults = UserDefaults.standard
        UpdateSettings.apply(to: defaults)

        let hostBundle = Bundle.main
        self.userDriver = UpdateDriver(viewModel: .init(), hostBundle: hostBundle)
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: userDriver
        )
#if DEBUG
        if let versionString = ProcessInfo.processInfo.environment["CMUX_UI_TEST_DEFERRED_UPDATE_VERSION"],
           !versionString.isEmpty {
            let displayVersionString = ProcessInfo.processInfo.environment["CMUX_UI_TEST_DEFERRED_UPDATE_DISPLAY_VERSION"] ?? versionString
            self.debugDeferredUpdateCandidate = .init(versionString: versionString, displayVersionString: displayVersionString)
        }
#endif
        installNoUpdateDismissObserver()
    }

    deinit {
        installCancellable?.cancel()
        attemptInstallCancellable?.cancel()
        noUpdateDismissCancellable?.cancel()
        noUpdateDismissWorkItem?.cancel()
        readyCheckWorkItem?.cancel()
        backgroundProbeTimer?.invalidate()
        latestItemProbe?.cancel()
    }

    /// Start the updater. If startup fails, the error is shown via the custom UI.
    func startUpdaterIfNeeded() {
        guard !didStartUpdater else { return }
        ensureSparkleInstallationCache()
#if DEBUG
        // Keep the permission-related defaults resettable for UI tests even though the
        // delegate now suppresses Sparkle's permission UI entirely.
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_RESET_SPARKLE_PERMISSION"] == "1" {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: UpdateSettings.automaticChecksKey)
            defaults.removeObject(forKey: UpdateSettings.automaticallyUpdateKey)
            defaults.removeObject(forKey: UpdateSettings.scheduledCheckIntervalKey)
            defaults.removeObject(forKey: UpdateSettings.sendProfileInfoKey)
            defaults.removeObject(forKey: UpdateSettings.migrationKey)
            defaults.synchronize()
            UpdateLogStore.shared.append("reset sparkle permission defaults (ui test)")
        }
#endif
        do {
            try updater.start()
            didStartUpdater = true
            let interval = Int(updater.updateCheckInterval.rounded())
            UpdateLogStore.shared.append(
                "updater started (autoChecks=\(updater.automaticallyChecksForUpdates), interval=\(interval)s, autoDownloads=\(updater.automaticallyDownloadsUpdates))"
            )
            startLaunchUpdateProbeIfNeeded()
        } catch {
            userDriver.viewModel.state = .error(.init(
                error: error,
                retry: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                    self?.didStartUpdater = false
                    self?.startUpdaterIfNeeded()
                },
                dismiss: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                }
            ))
        }
    }

    private func startLaunchUpdateProbeIfNeeded() {
        guard updater.automaticallyChecksForUpdates else {
            UpdateLogStore.shared.append("launch update probe skipped (automatic checks disabled)")
            return
        }

        // Probe immediately on launch so the sidebar can surface a passive update indicator
        // without waiting for Sparkle's scheduled check or opening interactive update UI.
        UpdateLogStore.shared.append("starting launch update probe")
        updater.checkForUpdateInformation()

        // Re-probe every hour so the banner appears even if the app has been running
        // for a while when a new version is published.
        backgroundProbeTimer?.invalidate()
        backgroundProbeTimer = Timer.scheduledTimer(withTimeInterval: backgroundProbeInterval, repeats: true) { [weak self] _ in
            guard let self, self.updater.automaticallyChecksForUpdates else { return }
            UpdateLogStore.shared.append("periodic background update probe")
            self.updater.checkForUpdateInformation()
        }
    }

    /// Force install the current update by auto-confirming all installable states.
    func installUpdate() {
        guard viewModel.state.isInstallable else { return }
        guard installCancellable == nil else { return }

        installCancellable = viewModel.$state.sink { [weak self] state in
            guard let self else { return }
            guard state.isInstallable else {
                self.installCancellable = nil
                return
            }
            state.confirm()
        }
    }

    /// Check for updates and auto-confirm install if one is found.
    func attemptUpdate() {
        stopAttemptUpdateMonitoring()
        didObserveAttemptUpdateProgress = false

        attemptInstallCancellable = viewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }

                if state.isInstallable || !state.isIdle {
                    self.didObserveAttemptUpdateProgress = true
                }

                if case .updateAvailable = state {
                    UpdateLogStore.shared.append("attemptUpdate auto-confirming available update")
                    state.confirm()
                    return
                }

                guard self.didObserveAttemptUpdateProgress, !state.isInstallable else {
                    return
                }
                self.stopAttemptUpdateMonitoring()
            }

        requestCheckForUpdates(presentation: .custom)
    }

    /// Check for updates (used by the menu item).
    @objc func checkForUpdates() {
        requestCheckForUpdates(presentation: .dialog)
    }

    private func requestCheckForUpdates(presentation: UpdateUserInitiatedCheckPresentation) {
        UpdateLogStore.shared.append("checkForUpdates invoked (state=\(viewModel.state.isIdle ? "idle" : "busy"), presentation=\(presentation == .dialog ? "dialog" : "custom"))")
        checkForUpdatesWhenReady(retries: readyRetryCount, presentation: presentation)
    }

    private func performCheckForUpdates(presentation: UpdateUserInitiatedCheckPresentation) {
        startUpdaterIfNeeded()
        ensureSparkleInstallationCache()
        refreshLatestUpdateSelectionIfNeeded(presentation: presentation) { [weak self] in
            self?.performUserInitiatedCheck(presentation: presentation)
        }
    }

    private func performUserInitiatedCheck(presentation: UpdateUserInitiatedCheckPresentation) {
        userDriver.prepareForUserInitiatedCheck(presentation: presentation)
        if viewModel.state == .idle || isShowingLatestItemProbeCheckingState {
            isShowingLatestItemProbeCheckingState = false
            updater.checkForUpdates()
            return
        }

        installCancellable?.cancel()
        viewModel.state.cancel()

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.userDriver.prepareForUserInitiatedCheck(presentation: presentation)
            self?.updater.checkForUpdates()
        }
    }

    /// Check for updates once the updater is ready (used by UI tests).
    func checkForUpdatesWhenReady(retries: Int = 10, presentation: UpdateUserInitiatedCheckPresentation = .dialog) {
        readyCheckWorkItem?.cancel()
        readyCheckWorkItem = nil
        startUpdaterIfNeeded()
        ensureSparkleInstallationCache()
        let canCheck = updater.canCheckForUpdates
        UpdateLogStore.shared.append("checkForUpdatesWhenReady invoked (canCheck=\(canCheck))")
        if canCheck {
            performCheckForUpdates(presentation: presentation)
            return
        }
        if viewModel.state.isIdle {
            viewModel.state = .checking(.init(cancel: {}))
        }
        guard retries > 0 else {
            UpdateLogStore.shared.append("checkForUpdatesWhenReady timed out")
            if case .checking = viewModel.state {
                viewModel.state = .error(.init(
                    error: NSError(
                        domain: "cmux.update",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Updater is still starting. Try again in a moment."]
                    ),
                    retry: { [weak self] in self?.requestCheckForUpdates(presentation: presentation) },
                    dismiss: { [weak self] in self?.viewModel.state = .idle }
                ))
            }
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.checkForUpdatesWhenReady(retries: retries - 1, presentation: presentation)
        }
        readyCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + readyRetryDelay, execute: workItem)
    }

    /// Validate the check for updates menu item.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) {
            // Always allow user-initiated checks; Sparkle can safely surface current progress.
            return true
        }
        return true
    }

    private func stopAttemptUpdateMonitoring() {
        attemptInstallCancellable?.cancel()
        attemptInstallCancellable = nil
        didObserveAttemptUpdateProgress = false
    }

    private func installNoUpdateDismissObserver() {
        noUpdateDismissCancellable = Publishers.CombineLatest(viewModel.$state, viewModel.$overrideState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, overrideState in
                self?.scheduleNoUpdateDismiss(for: state, overrideState: overrideState)
            }
    }

    private func scheduleNoUpdateDismiss(for state: UpdateState, overrideState: UpdateState?) {
        noUpdateDismissWorkItem?.cancel()
        noUpdateDismissWorkItem = nil

        guard overrideState == nil else { return }
        guard case .notFound(let notFound) = state else { return }

        recordUITestTimestamp(key: "noUpdateShownAt")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.viewModel.overrideState == nil,
                  case .notFound = self.viewModel.state else { return }

            withAnimation(.easeInOut(duration: 0.25)) {
                self.recordUITestTimestamp(key: "noUpdateHiddenAt")
                self.viewModel.state = .idle
            }
            notFound.acknowledgement()
        }
        noUpdateDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + UpdateTiming.noUpdateDisplayDuration,
            execute: workItem
        )
    }

    private func recordUITestTimestamp(key: String) {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_MODE"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_TIMING_PATH"] else { return }

        let url = URL(fileURLWithPath: path)
        var payload: [String: Double] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
            payload = object
        }
        payload[key] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: url)
        }
#endif
    }

    private func ensureSparkleInstallationCache() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }

        let baseURL = cachesURL
            .appendingPathComponent(bundleIdentifier)
            .appendingPathComponent("org.sparkle-project.Sparkle")
        let installURL = baseURL.appendingPathComponent("Installation")

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: installURL.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                do {
                    try FileManager.default.removeItem(at: installURL)
                } catch {
                    UpdateLogStore.shared.append("Failed removing Sparkle installation cache file: \(error)")
                    return
                }
            } else {
                return
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: installURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            UpdateLogStore.shared.append("Ensured Sparkle installation cache at \(installURL.path)")
        } catch {
            UpdateLogStore.shared.append("Failed creating Sparkle installation cache: \(error)")
        }
    }

    private func refreshLatestUpdateSelectionIfNeeded(
        presentation: UpdateUserInitiatedCheckPresentation,
        completion: @escaping () -> Void
    ) {
        // Sparkle resumes cached deferred updates before fetching the feed again.
        // Probe the latest appcast first so a manual check doesn't surface an older cached version.
        guard latestItemProbe == nil else {
            latestItemProbeQueuedFollowUp = completion
            UpdateLogStore.shared.append(
                "latest update probe already in progress; coalescing latest user check (presentation=\(presentation == .dialog ? "dialog" : "custom"))"
            )
            return
        }
        guard let deferredUpdateCandidate = currentDeferredUpdateCandidate() else {
            completion()
            return
        }

        if viewModel.state == .idle {
            isShowingLatestItemProbeCheckingState = true
            viewModel.state = .checking(.init(cancel: { [weak self] in
                self?.cancelLatestItemProbe()
            }))
        }

        UpdateLogStore.shared.append(
            "probing latest update before user check (deferred=\(deferredUpdateCandidate.displayVersionString), presentation=\(presentation == .dialog ? "dialog" : "custom"))"
        )

        let probe = UpdateLatestItemProbe()
        latestItemProbe = probe
        latestItemProbeQueuedFollowUp = nil
        probe.start { [weak self] result in
            guard let self else { return }
            self.latestItemProbe = nil
            let followUp = self.latestItemProbeQueuedFollowUp ?? completion
            self.latestItemProbeQueuedFollowUp = nil

            if let latestValidUpdate = result.latestValidUpdate,
               self.shouldReplaceDeferredUpdate(
                   deferredUpdateCandidate,
                   with: latestValidUpdate
               ) {
                self.clearDeferredUpdateCandidate()
                UpdateLogStore.shared.append(
                    "cleared stale deferred update \(deferredUpdateCandidate.displayVersionString) in favor of \(latestValidUpdate.displayVersionString)"
                )
            } else if let error = result.error {
                UpdateLogStore.shared.append("latest update probe failed: \(self.userDriver.formatErrorForLog(error))")
            }

            followUp()
        }
    }

    private func cancelLatestItemProbe() {
        guard latestItemProbe != nil || latestItemProbeQueuedFollowUp != nil || isShowingLatestItemProbeCheckingState else {
            return
        }

        UpdateLogStore.shared.append("latest update probe canceled")
        latestItemProbe?.cancel()
        latestItemProbe = nil
        latestItemProbeQueuedFollowUp = nil

        guard isShowingLatestItemProbeCheckingState else { return }
        isShowingLatestItemProbeCheckingState = false
        if case .checking = viewModel.state {
            viewModel.state = .idle
        }
    }

    private func currentDeferredUpdateCandidate() -> DeferredUpdateCandidate? {
#if DEBUG
        if let debugDeferredUpdateCandidate {
            return debugDeferredUpdateCandidate
        }
#endif
        return SparkleResumableUpdateReflection.deferredUpdateCandidate(from: updater)
    }

    private func clearDeferredUpdateCandidate() {
#if DEBUG
        debugDeferredUpdateCandidate = nil
#endif
        _ = SparkleResumableUpdateReflection.clearDeferredUpdate(from: updater)
    }

    private func shouldReplaceDeferredUpdate(
        _ deferredUpdateCandidate: DeferredUpdateCandidate,
        with latestValidUpdate: DeferredUpdateCandidate
    ) -> Bool {
        let latestVersionString = effectiveVersionString(for: latestValidUpdate)
        let deferredVersionString = effectiveVersionString(for: deferredUpdateCandidate)
        guard !latestVersionString.isEmpty, !deferredVersionString.isEmpty else {
            return false
        }
        let comparison = SUStandardVersionComparator.default.compareVersion(
            deferredVersionString,
            toVersion: latestVersionString
        )
        return comparison == .orderedAscending
    }

    private func effectiveVersionString(for deferredUpdateCandidate: DeferredUpdateCandidate) -> String {
        deferredUpdateCandidate.versionString.isEmpty ? deferredUpdateCandidate.displayVersionString : deferredUpdateCandidate.versionString
    }
}

private struct DeferredUpdateCandidate {
    let versionString: String
    let displayVersionString: String

    init(versionString: String, displayVersionString: String) {
        self.versionString = versionString
        self.displayVersionString = displayVersionString
    }

    init(item: SUAppcastItem) {
        self.init(versionString: item.versionString, displayVersionString: item.displayVersionString)
    }
}

private enum SparkleResumableUpdateReflection {
    private static let resumableUpdateIvarName = "_resumableUpdate"

    static func deferredUpdateCandidate(from updater: SPUUpdater) -> DeferredUpdateCandidate? {
        guard let resumableUpdate = resumableUpdateObject(from: updater),
              let updateItem = resumableUpdate.perform(NSSelectorFromString("updateItem"))?.takeUnretainedValue() as? SUAppcastItem else {
            return nil
        }
        return DeferredUpdateCandidate(item: updateItem)
    }

    @discardableResult
    static func clearDeferredUpdate(from updater: SPUUpdater) -> Bool {
        guard let resumableUpdateIvar = class_getInstanceVariable(SPUUpdater.self, resumableUpdateIvarName) else {
            return false
        }
        object_setIvar(updater, resumableUpdateIvar, nil)
        return true
    }

    private static func resumableUpdateObject(from updater: SPUUpdater) -> NSObject? {
        guard let resumableUpdateIvar = class_getInstanceVariable(SPUUpdater.self, resumableUpdateIvarName),
              let resumableUpdate = object_getIvar(updater, resumableUpdateIvar) else {
            return nil
        }
        return resumableUpdate as? NSObject
    }
}

private final class UpdateLatestItemProbe: NSObject {
    struct Result {
        let latestValidUpdate: DeferredUpdateCandidate?
        let error: Error?
    }

    private let stateLock = NSLock()
    private var completionHandler: ((Result) -> Void)?
    private var dataTask: URLSessionDataTask?

    func start(completion: @escaping (Result) -> Void) {
        stateLock.lock()
        completionHandler = completion
        stateLock.unlock()

        guard let feedURLString = resolvedFeedURLString(),
              let feedURL = URL(string: feedURLString) else {
            deliver(.init(latestValidUpdate: nil, error: nil))
            return
        }

#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let override = env["CMUX_UI_TEST_FEED_URL"], !override.isEmpty {
            UpdateTestURLProtocol.registerIfNeeded()
        }
#endif

        let task = URLSession.shared.dataTask(with: feedURL) { [weak self] data, _, error in
            let result: Result
            if let error {
                result = .init(latestValidUpdate: nil, error: error)
            } else if let data {
                do {
                    let parser = LatestAppcastFeedParser()
                    let items = try parser.parse(data: data)
                    result = .init(
                        latestValidUpdate: Self.pickLatestItem(from: items),
                        error: nil
                    )
                } catch {
                    result = .init(latestValidUpdate: nil, error: error)
                }
            } else {
                result = .init(latestValidUpdate: nil, error: nil)
            }

            self?.deliver(result)
        }
        stateLock.lock()
        dataTask = task
        stateLock.unlock()
        task.resume()
    }

    func cancel() {
        let task: URLSessionDataTask?
        stateLock.lock()
        task = dataTask
        dataTask = nil
        completionHandler = nil
        stateLock.unlock()
        task?.cancel()
    }

    private func deliver(_ result: Result) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let completion = self.takeCompletion()
            guard let completion else { return }
            completion(result)
        }
    }

    private func takeCompletion() -> ((Result) -> Void)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let completion = completionHandler
        completionHandler = nil
        dataTask = nil
        return completion
    }

    private func resolvedFeedURLString() -> String? {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let override = env["CMUX_UI_TEST_FEED_URL"], !override.isEmpty {
            return override
        }
#endif
        let infoFeedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        return UpdateFeedResolver.resolvedFeedURLString(infoFeedURL: infoFeedURL).url
    }

    private static func pickLatestItem(from items: [DeferredUpdateCandidate]) -> DeferredUpdateCandidate? {
        var latestItem: DeferredUpdateCandidate?
        for item in items {
            guard let currentLatest = latestItem else {
                latestItem = item
                continue
            }
            let comparison = SUStandardVersionComparator.default.compareVersion(
                effectiveVersionString(for: currentLatest),
                toVersion: effectiveVersionString(for: item)
            )
            if comparison == .orderedAscending {
                latestItem = item
            }
        }
        return latestItem
    }

    private static func effectiveVersionString(for item: DeferredUpdateCandidate) -> String {
        item.versionString.isEmpty ? item.displayVersionString : item.versionString
    }
}

private final class LatestAppcastFeedParser: NSObject, XMLParserDelegate {
    private struct ParsedItem {
        var versionString = ""
        var displayVersionString = ""
        var channel: String?
        var minimumSystemVersion: String?
        var maximumSystemVersion: String?
        var hasDownload = false
        var hasInfoURL = false
    }

    private var parsedItems: [DeferredUpdateCandidate] = []
    private var currentItem: ParsedItem?
    private var currentText = ""

    func parse(data: Data) throws -> [DeferredUpdateCandidate] {
        parsedItems = []
        currentItem = nil
        currentText = ""

        let parser = XMLParser(data: data)
        parser.delegate = self
        if parser.parse() {
            return parsedItems
        }

        throw parser.parserError ?? NSError(
            domain: "cmux.update",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Failed to parse update feed."]
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        currentText = ""

        switch name {
        case "item":
            currentItem = ParsedItem()
        case "enclosure":
            guard currentItem != nil else { return }
            currentItem?.hasDownload = true
            if let versionString = attributeDict["sparkle:version"], !versionString.isEmpty {
                currentItem?.versionString = versionString
            }
            if let displayVersionString = attributeDict["sparkle:shortVersionString"], !displayVersionString.isEmpty {
                currentItem?.displayVersionString = displayVersionString
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard currentItem != nil else {
            currentText = ""
            return
        }

        switch name {
        case "sparkle:version":
            if !text.isEmpty {
                currentItem?.versionString = text
            }
        case "sparkle:shortVersionString":
            if !text.isEmpty {
                currentItem?.displayVersionString = text
            }
        case "sparkle:channel":
            currentItem?.channel = text.isEmpty ? nil : text
        case "sparkle:minimumSystemVersion":
            currentItem?.minimumSystemVersion = text.isEmpty ? nil : text
        case "sparkle:maximumSystemVersion":
            currentItem?.maximumSystemVersion = text.isEmpty ? nil : text
        case "link":
            if !text.isEmpty {
                currentItem?.hasInfoURL = true
            }
        case "item":
            finalizeCurrentItem()
        default:
            break
        }

        currentText = ""
    }

    private func finalizeCurrentItem() {
        guard let currentItem else { return }
        defer { self.currentItem = nil }

        guard currentItem.channel == nil else { return }
        guard currentItem.hasDownload || currentItem.hasInfoURL else { return }
        let versionString = currentItem.versionString
        guard !versionString.isEmpty else { return }
        guard passesMinimumSystemVersion(currentItem.minimumSystemVersion) else { return }
        guard passesMaximumSystemVersion(currentItem.maximumSystemVersion) else { return }

        let displayVersionString = currentItem.displayVersionString.isEmpty
            ? versionString
            : currentItem.displayVersionString
        parsedItems.append(
            DeferredUpdateCandidate(
                versionString: versionString,
                displayVersionString: displayVersionString
            )
        )
    }

    private func passesMinimumSystemVersion(_ versionString: String?) -> Bool {
        guard let versionString, !versionString.isEmpty else { return true }
        return compareSystemVersion(versionString, to: currentSystemVersionString) != .orderedDescending
    }

    private func passesMaximumSystemVersion(_ versionString: String?) -> Bool {
        guard let versionString, !versionString.isEmpty else { return true }
        return compareSystemVersion(versionString, to: currentSystemVersionString) != .orderedAscending
    }

    private var currentSystemVersionString: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private func compareSystemVersion(_ lhs: String, to rhs: String) -> ComparisonResult {
        let lhsComponents = versionComponents(from: lhs)
        let rhsComponents = versionComponents(from: rhs)
        let count = max(lhsComponents.count, rhsComponents.count)
        for index in 0..<count {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue < rhsValue {
                return .orderedAscending
            }
            if lhsValue > rhsValue {
                return .orderedDescending
            }
        }
        return .orderedSame
    }

    private func versionComponents(from versionString: String) -> [Int] {
        versionString
            .split(separator: ".")
            .compactMap { Int($0) }
    }
}
