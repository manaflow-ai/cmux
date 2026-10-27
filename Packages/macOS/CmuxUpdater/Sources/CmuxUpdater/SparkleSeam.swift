public import Foundation
@preconcurrency public import Sparkle

// The one file that imports Sparkle (plans/cmux-next/chrome-parity/p10-stability.md, task 046).
// Sparkle's Objective-C API is wrapped here in cmux-owned Sendable values and one @MainActor
// bridge; the rest of the package and its clients see only these types, so Sparkle's
// concurrency annotations are trusted in exactly one place. Chromium keeps its updater client
// behind the same kind of boundary (chrome/browser/updater/browser_updater_client.h).

// MARK: - Appcast item

/// One update a Sparkle appcast offers: the values the update flow and its UI read.
///
/// Wraps Sparkle's immutable, `Sendable` appcast item; the item itself only travels back to
/// Sparkle through ``SparkleDriverBridge``.
public struct UpdateAppcastItem: Sendable {
    fileprivate let sparkle: SUAppcastItem

    fileprivate init(_ sparkle: SUAppcastItem) {
        self.sparkle = sparkle
    }

    /// Parses an item from an appcast `<item>` dictionary (`enclosure`, `pubDate`, `title`, ...),
    /// or nil when Sparkle rejects it. Used by UI test scaffolding and tests.
    public init?(dictionary: [String: Any]) {
        guard let item = SUAppcastItem(dictionary: dictionary) else { return nil }
        self.sparkle = item
    }

    /// An item with no version, enclosure or notes.
    public static func empty() -> UpdateAppcastItem {
        UpdateAppcastItem(SUAppcastItem.empty())
    }

    /// The human-readable version (`sparkle:shortVersionString`, else `sparkle:version`).
    public var displayVersionString: String { sparkle.displayVersionString }
    /// The build Sparkle compares (`sparkle:version`).
    public var versionString: String { sparkle.versionString }
    /// The item's publication date (`pubDate`), when it has one.
    public var date: Date? { sparkle.date }
    /// The item's inline release notes (`description`), when it has them.
    public var itemDescription: String? { sparkle.itemDescription }
    /// The full archive's byte count (`enclosure length`).
    public var contentLength: UInt64 { sparkle.contentLength }
    /// The full archive's URL (`enclosure url`).
    public var fileURL: URL? { sparkle.fileURL }
    /// Whether the item lists any delta update.
    public var listsDeltas: Bool { !(sparkle.deltaUpdates?.isEmpty ?? true) }
}

// MARK: - Choices, checks and permission

/// The answer to an update prompt, Sparkle's `SPUUserUpdateChoice` (same raw values).
public enum UpdateChoice: Int, Sendable {
    /// Skips this version: it is not offered again unless the person checks.
    case skip = 0
    /// Downloads, extracts or installs the update.
    case install = 1
    /// Dismisses the update for now.
    case dismiss = 2

    fileprivate var sparkle: SPUUserUpdateChoice {
        switch self {
        case .skip: .skip
        case .install: .install
        case .dismiss: .dismiss
        }
    }
}

/// The kind of check a finished Sparkle update cycle ran, Sparkle's `SPUUpdateCheck`
/// (same raw values, which the update log prints).
enum UpdateCheckKind: Int, Sendable {
    /// A foreground check that may show an update prompt.
    case updates = 0
    /// A scheduled or background check.
    case updatesInBackground = 1
    /// A probe that only reads what the feed offers.
    case updateInformation = 2

    fileprivate init(_ check: SPUUpdateCheck) {
        switch check {
        case .updates: self = .updates
        case .updatesInBackground: self = .updatesInBackground
        case .updateInformation: self = .updateInformation
        @unknown default: self = .updates
        }
    }
}

/// The answer to Sparkle's permission request for automatic checks.
public struct UpdatePermissionResponse: Sendable, Equatable {
    /// Whether scheduled checks run.
    public let automaticUpdateChecks: Bool
    /// Whether checks send the system profile.
    public let sendSystemProfile: Bool

    /// Creates a response.
    public init(automaticUpdateChecks: Bool, sendSystemProfile: Bool) {
        self.automaticUpdateChecks = automaticUpdateChecks
        self.sendSystemProfile = sendSystemProfile
    }

    fileprivate var sparkle: SUUpdatePermissionResponse {
        SUUpdatePermissionResponse(automaticUpdateChecks: automaticUpdateChecks, sendSystemProfile: sendSystemProfile)
    }
}

/// What Sparkle's no-update result says, read from its error's `userInfo`.
struct SparkleNoUpdateFound: Sendable, Equatable {
    /// Why no update was offered (`SPUNoUpdateFoundReason`, by name).
    let reason: String
    /// Whether the person started the check.
    let userInitiated: Bool
    /// The newest item the feed listed, or empty.
    let latestDisplayVersion: String

    init(_ error: any Error) {
        let nsError = error as NSError
        let reasonValue = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        let reason = reasonValue.map { SPUNoUpdateFoundReason(rawValue: OSStatus($0)) } ?? nil
        self.reason = reason.map(describeNoUpdateFoundReason) ?? "unknown"
        self.userInitiated = (nsError.userInfo[SPUNoUpdateFoundUserInitiatedKey] as? NSNumber)?.boolValue ?? false
        let latestItem = nsError.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        self.latestDisplayVersion = latestItem?.displayVersionString ?? ""
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

extension UpdateStateModel {
    /// The `NSError` domain of Sparkle's own errors (`SUSparkleErrorDomain`); codes are `SUError`.
    nonisolated static let sparkleErrorDomain: String = SUSparkleErrorDomain
}

// MARK: - Version order

/// Sparkle's ordering of `CFBundleVersion` strings (`SUStandardVersionComparator`).
public struct SparkleVersionComparator: Sendable {
    /// Creates the comparator.
    public init() {}

    /// Orders `lhs` against `rhs` as Sparkle does when it picks an update.
    public func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        SUStandardVersionComparator.default.compareVersion(lhs, toVersion: rhs)
    }
}

// MARK: - Updater

extension SPUUpdater: UpdaterHandle {}

extension UpdateDriver {
    /// The real Sparkle updater, driven by this driver through a ``SparkleDriverBridge``.
    /// Sparkle retains its user driver (the bridge); the bridge is also its weak delegate.
    func makeSparkleUpdater(hostBundle: Bundle) -> any UpdaterHandle {
        let bridge = SparkleDriverBridge(driver: self)
        return SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: bridge,
            delegate: bridge
        )
    }
}

// MARK: - Driver and delegate bridge

/// Sparkle's `SPUUserDriver` and `SPUUpdaterDelegate`, translated into ``UpdateDriver`` calls
/// with cmux values. It holds no state: every callback forwards on the main actor, where Sparkle
/// makes it. It implements exactly the optional delegate methods the driver answers, because
/// Sparkle changes behavior on `respondsToSelector:` (`SparkleSeamTests` pins the selector set).
///
/// Callbacks that carry an object only Sparkle can make (`SPUUpdater`, `SPUUserUpdateState`,
/// `SPUUpdatePermissionRequest`) and ignore it hand their translation to a `forward...` method,
/// so tests check each value conversion without building those objects.
@MainActor
final class SparkleDriverBridge: NSObject, @preconcurrency SPUUserDriver, @preconcurrency SPUUpdaterDelegate {
    private let driver: UpdateDriver

    init(driver: UpdateDriver) {
        self.driver = driver
        super.init()
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
        forwardPermissionRequest(reply: reply)
    }

    /// Answers Sparkle's permission request with the driver's response.
    func forwardPermissionRequest(reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
        driver.showPermissionRequest { response in reply(response.sparkle) }
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        driver.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        forwardUpdateFound(UpdateAppcastItem(appcastItem), reply: reply)
    }

    /// Offers `item` through the driver; its answer reaches Sparkle as `SPUUserUpdateChoice`.
    func forwardUpdateFound(_ item: UpdateAppcastItem,
                            reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        driver.showUpdateFound(with: item) { choice in reply(choice.sparkle) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // cmux uses Sparkle's UI for release notes links instead.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // Release notes are handled via link buttons.
    }

    func showUpdateNotFoundWithError(_ error: any Error,
                                     acknowledgement: @escaping () -> Void) {
        driver.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: any Error,
                          acknowledgement: @escaping () -> Void) {
        driver.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        driver.showDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        driver.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        driver.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        driver.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        driver.showExtractionReceivedProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        driver.showReady { choice in reply(choice.sparkle) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        driver.showInstallingUpdate(retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        driver.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func showUpdateInFocus() {
        // No-op; cmux never shows Sparkle dialogs.
    }

    func dismissUpdateInstallation() {
        driver.dismissUpdateInstallation()
    }

    // MARK: SPUUpdaterDelegate

    func updaterShouldPromptForPermissionToCheck(forUpdates _: SPUUpdater) -> Bool {
        false
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        driver.feedURLStringForCheck()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        driver.allowedChannels()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        driver.handleWillInstallUpdate(UpdateAppcastItem(item))
    }

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        driver.handleWillScheduleUpdateCheck(afterDelay: delay)
    }

    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        driver.handleWillNotScheduleUpdateCheck()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        driver.handleWillInstallUpdateOnQuit(UpdateAppcastItem(item), immediateInstallHandler: immediateInstallHandler)
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        driver.handleDidFinishLoadingAppcast(
            itemCount: appcast.items.count,
            firstDisplayVersion: appcast.items.first?.displayVersionString ?? ""
        )
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        driver.handleDidFindValidUpdate(UpdateAppcastItem(item))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        driver.handleDidNotFindUpdate(error)
    }

    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        forwardUpdateCycleFinished(updateCheck, error: error)
    }

    /// Tells the driver that Sparkle's update cycle for `updateCheck` ended.
    func forwardUpdateCycleFinished(_ updateCheck: SPUUpdateCheck, error: (any Error)?) {
        driver.handleDidFinishUpdateCycle(UpdateCheckKind(updateCheck), error: error)
    }

    func updater(_ updater: SPUUpdater, userDidMake _: SPUUserUpdateChoice, forUpdate _: SUAppcastItem, state _: SPUUserUpdateState) {
        driver.handleUserDidMakeChoice()
    }

    func updater(_ updater: SPUUpdater,
                 shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        driver.handleShouldPostponeRelaunch(item: UpdateAppcastItem(item), installHandler: installHandler)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        driver.handleWillRelaunchApplication()
    }
}
