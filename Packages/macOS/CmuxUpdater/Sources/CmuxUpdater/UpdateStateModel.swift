public import Foundation
@preconcurrency public import Sparkle
import Observation

/// The observable source of truth for the custom update UI.
///
/// `UpdateStateModel` holds the current ``UpdateState`` (plus an optional `overrideState` used
/// by debug tooling), the most recently detected background update, and a set of derived,
/// localized display strings the UI renders. It is observed directly by SwiftUI via the
/// Observation framework; appearance (color) derivations live in the `CmuxUpdaterUI` package.
///
/// State transitions funnel through ``setState(_:)`` / ``setOverrideState(_:)`` (and the
/// higher-level mutators), which both apply the change and emit on the ``stateChanges()``
/// stream. ``UpdateController`` consumes that stream to drive force-install, attempt-update,
/// and the auto-dismiss of a "no updates" result — replacing the previous Combine
/// `@Published` subscriptions.
///
/// All access is main-actor isolated; ``UpdateState`` values never cross an actor boundary, so
/// the non-`Sendable` callbacks they carry are safe.
@MainActor
@Observable
public final class UpdateStateModel {
    /// The current update phase as driven by Sparkle.
    public private(set) var state: UpdateState = .idle
    /// A debug/override phase that, when set, takes precedence over ``state`` for display.
    public private(set) var overrideState: UpdateState?
    /// The display version of the most recently detected background update, if any.
    public private(set) var detectedUpdateVersion: String?
    /// The appcast item for the most recently detected background update, if any.
    public private(set) var detectedUpdateItem: SUAppcastItem?
    /// The staged-update version whose "update ready" toast the user dismissed. Compared against
    /// the staged version so the toast stays hidden for that version but re-shows when a newer
    /// release is staged.
    public private(set) var dismissedUpdateReadyToastVersion: String?
    /// Whether the user asked to defer the staged update's restart until the Mac is idle.
    public private(set) var isRestartWhenIdleArmed = false
    /// The deadline until which the update-ready toast is muted (any version). Persisted so a
    /// multi-day mute survives relaunches; the pill remains the ambient affordance meanwhile.
    public private(set) var updateReadyToastMutedUntil: Date?
    #if DEBUG
    /// A debug override for the pill's title text.
    public var debugOverrideText: String?
    #endif

    /// Continuations for active ``stateChanges()`` subscribers, keyed by subscription id.
    @ObservationIgnored
    private var changeObservers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// The `UserDefaults` key persisting ``updateReadyToastMutedUntil`` (epoch seconds).
    public static let toastMuteDefaultsKey = "cmux.update.readyToastMutedUntil"
    @ObservationIgnored
    private let defaults: UserDefaults
    /// Current-time source; injectable so mute-expiry behavior is testable.
    @ObservationIgnored
    var now: () -> Date = Date.init

    /// Creates an empty model in the ``UpdateState/idle`` state, restoring any persisted
    /// toast-mute deadline from `defaults`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let epoch = defaults.object(forKey: Self.toastMuteDefaultsKey) as? Double {
            updateReadyToastMutedUntil = Date(timeIntervalSince1970: epoch)
        }
    }

    // MARK: - Change stream

    /// A stream that emits once whenever ``state`` or ``overrideState`` changes.
    ///
    /// The element is `Void`: subscribers read the latest ``state``/``overrideState`` directly
    /// (both are main-actor isolated like the subscriber), which avoids sending the
    /// non-`Sendable` ``UpdateState`` across the stream. This is the `@Observable`-native
    /// replacement for observing `@Published var state`.
    public func stateChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            changeObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.changeObservers[id] = nil }
            }
        }
    }

    private func notifyStateChanged() {
        for continuation in changeObservers.values {
            continuation.yield(())
        }
    }

    // MARK: - State mutation (the single write funnel)

    /// Sets ``state`` and notifies ``stateChanges()`` subscribers.
    public func setState(_ newState: UpdateState) {
        state = newState
        disarmRestartWhenIdleIfNotInstalling()
        notifyStateChanged()
    }

    /// Sets ``overrideState`` and notifies ``stateChanges()`` subscribers.
    public func setOverrideState(_ newState: UpdateState?) {
        overrideState = newState
        disarmRestartWhenIdleIfNotInstalling()
        notifyStateChanged()
    }

    /// The deferred restart only makes sense while an update is staged; leaving
    /// `.installing` (dismiss, error, new check) disarms it.
    private func disarmRestartWhenIdleIfNotInstalling() {
        if isRestartWhenIdleArmed, !effectiveState.isInstalling {
            isRestartWhenIdleArmed = false
        }
    }

    /// Applies a state produced by the Sparkle driver, recording the detected update first
    /// when the new state is ``UpdateState/updateAvailable(_:)``.
    public func applyDriverState(_ newState: UpdateState) {
        if case .updateAvailable(let update) = newState {
            recordDetectedUpdate(update.appcastItem)
        }
        setState(newState)
    }

    /// Cancels whatever phase is active and returns the model to ``UpdateState/idle``,
    /// clearing any override. Used when starting a fresh check.
    public func cancelActiveStateForNewCheck() {
        state.cancel()
        // One conceptual transition: update both fields, then emit a single change notification
        // (avoids two redundant stateChanges() emissions for one logical reset).
        state = .idle
        overrideState = nil
        notifyStateChanged()
    }

    // MARK: - Detected background update

    /// Records a background-detected available update (or clears it when the version string
    /// is unusable).
    public func recordDetectedUpdate(_ item: SUAppcastItem) {
        let version = Self.normalizedDetectedUpdateVersion(from: item.displayVersionString)
        detectedUpdateItem = version == nil ? nil : item
        detectedUpdateVersion = version
    }

    /// Clears any detected background update.
    public func clearDetectedUpdate() {
        detectedUpdateItem = nil
        detectedUpdateVersion = nil
    }

    #if DEBUG
    /// Sets the detected-update version directly without an appcast item. DEBUG-only, for UI
    /// test scaffolding that wants to surface the passive banner without a real appcast.
    public func debugSetDetectedVersion(_ version: String?) {
        detectedUpdateItem = nil
        detectedUpdateVersion = version
    }

    /// Overrides the state with a synthetic error so the matching error popover can be previewed
    /// from the debug menu. DEBUG-only.
    public func debugShowUpdateError(_ scenario: DebugUpdateErrorScenario) {
        setOverrideState(.error(.init(
            error: scenario.error,
            retry: { [weak self] in self?.setOverrideState(nil) },
            dismiss: { [weak self] in self?.setOverrideState(nil) },
            technicalDetails: "debug scenario: \(scenario.rawValue)",
            feedURLString: "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml"
        )))
    }
    #endif

    /// Dismisses a detected available update, replying `.dismiss` to Sparkle for whichever of
    /// ``state``/``overrideState`` is carrying it, and clearing the detected-update banner.
    public func dismissDetectedAvailableUpdate() {
        clearDetectedUpdate()

        var didDismissUpdate = false
        if case .updateAvailable(let update) = state {
            update.reply(.dismiss)
            didDismissUpdate = true
            setState(.idle)
        }

        if let overrideState, case .updateAvailable(let update) = overrideState {
            if !didDismissUpdate {
                update.reply(.dismiss)
            }
            setOverrideState(nil)
        }
    }

    // MARK: - Update-ready toast

    /// The staged install the "update ready" toast should render, or `nil` when no toast should
    /// show. A toast shows while an automatically-downloaded update is staged for install,
    /// until the user dismisses it for that version or defers the restart to idle time.
    public var updateReadyToastInstalling: UpdateState.Installing? {
        guard case .installing(let installing) = effectiveState, installing.isAutoUpdate else {
            return nil
        }
        guard !isRestartWhenIdleArmed else { return nil }
        if let mutedUntil = updateReadyToastMutedUntil, now() < mutedUntil {
            return nil
        }
        guard dismissedUpdateReadyToastVersion != Self.toastVersionKey(for: installing) else {
            return nil
        }
        return installing
    }

    /// Mutes the update-ready toast (for any staged version) for `duration`, persisting the
    /// deadline across relaunches. The pill keeps showing the staged install. An expired mute
    /// re-surfaces the toast on the next update-state change or launch.
    public func muteUpdateReadyToast(for duration: TimeInterval) {
        let until = now().addingTimeInterval(duration)
        updateReadyToastMutedUntil = until
        defaults.set(until.timeIntervalSince1970, forKey: Self.toastMuteDefaultsKey)
        notifyStateChanged()
    }

    /// Clears any toast mute (used by test scaffolding for deterministic launches).
    public func clearUpdateReadyToastMute() {
        updateReadyToastMutedUntil = nil
        defaults.removeObject(forKey: Self.toastMuteDefaultsKey)
    }

    /// Hides the update-ready toast for the currently staged version. It re-shows only when a
    /// different version is staged.
    public func dismissUpdateReadyToast() {
        guard case .installing(let installing) = effectiveState else { return }
        dismissedUpdateReadyToastVersion = Self.toastVersionKey(for: installing)
    }

    /// Arms or disarms the deferred "restart when idle" for the staged update.
    public func setRestartWhenIdleArmed(_ armed: Bool) {
        guard isRestartWhenIdleArmed != armed else { return }
        isRestartWhenIdleArmed = armed
        notifyStateChanged()
    }

    private static func toastVersionKey(for installing: UpdateState.Installing) -> String {
        installing.stagedVersion ?? ""
    }

    // MARK: - Derived display state

    /// The phase to display: the override if present, otherwise ``state``.
    public var effectiveState: UpdateState {
        overrideState ?? state
    }

    /// Whether to surface a passive "update available" banner detected in the background while
    /// the foreground flow is idle.
    public var showsDetectedBackgroundUpdate: Bool {
        effectiveState.isIdle && detectedUpdateVersion != nil
    }

    /// Whether cached appcast details exist for the detected background update.
    public var hasCachedDetectedUpdateDetails: Bool {
        detectedUpdateItem != nil
    }

    /// Whether the update pill should be visible.
    public var showsPill: Bool {
        !effectiveState.isIdle || showsDetectedBackgroundUpdate
    }

    /// The pill's title text for the current phase.
    public var text: String {
        #if DEBUG
        if let debugOverrideText { return debugOverrideText }
        #endif
        if let detectedText = detectedUpdateText {
            return detectedText
        }
        switch effectiveState {
        case .idle:
            return ""
        case .permissionRequest:
            return String(localized: "update.permissionRequest.text", defaultValue: "Enable Automatic Updates?")
        case .checking:
            return String(localized: "update.checking", defaultValue: "Checking for Updates…")
        case .updateAvailable(let update):
            let version = update.appcastItem.displayVersionString
            if !version.isEmpty {
                return String(localized: "update.available.withVersion", defaultValue: "Update Available: \(version)")
            }
            return String(localized: "update.available.short", defaultValue: "Update Available")
        case .downloading(let download):
            if let expectedLength = download.expectedLength, expectedLength > 0 {
                let progress = Double(download.progress) / Double(expectedLength)
                let percent = String(format: "%.0f%%", progress * 100)
                return String(localized: "update.downloading.progress", defaultValue: "Downloading: \(percent)")
            }
            return String(localized: "update.downloading.status", defaultValue: "Downloading…")
        case .extracting(let extracting):
            let percent = String(format: "%.0f%%", extracting.progress * 100)
            return String(localized: "update.extracting.progress", defaultValue: "Preparing: \(percent)")
        case .installing(let install):
            guard install.isAutoUpdate else {
                return String(localized: "update.installing.status", defaultValue: "Installing…")
            }
            if isRestartWhenIdleArmed {
                return String(localized: "update.restartingWhenIdle", defaultValue: "Restarting When Idle…")
            }
            return String(localized: "update.restartToComplete", defaultValue: "Restart to Complete Update")
        case .notFound:
            return String(localized: "update.noUpdates.title", defaultValue: "No Updates Available")
        case .error(let err):
            return Self.userFacingErrorTitle(for: err.error)
        }
    }

    /// The widest title text the pill can show for the current phase, used to reserve layout
    /// width so the pill does not resize as progress ticks.
    public var maxWidthText: String {
        if let detectedText = detectedUpdateText {
            return detectedText
        }
        switch effectiveState {
        case .downloading:
            return "Downloading: 100%"
        case .extracting:
            return "Preparing: 100%"
        default:
            return text
        }
    }

    /// The SF Symbol name for the current phase, or `nil` when idle.
    public var iconName: String? {
        if showsDetectedBackgroundUpdate {
            return "shippingbox.fill"
        }
        switch effectiveState {
        case .idle:
            return nil
        case .permissionRequest:
            return "questionmark.circle"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .updateAvailable:
            return "shippingbox.fill"
        case .downloading:
            return "arrow.down.circle"
        case .extracting:
            return "shippingbox"
        case .installing:
            return "power.circle"
        case .notFound:
            return "info.circle"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    /// A one-line description of the current phase for the popover.
    public var description: String {
        switch effectiveState {
        case .idle:
            return ""
        case .permissionRequest:
            return String(localized: "update.configureAutoUpdates", defaultValue: "Configure automatic update preferences")
        case .checking:
            return String(localized: "update.pleaseWait", defaultValue: "Please wait while we check for available updates")
        case .updateAvailable(let update):
            return update.releaseNotes?.label ?? String(localized: "update.downloadAndInstall", defaultValue: "Download and install the latest version")
        case .downloading:
            return String(localized: "update.downloadingPackage", defaultValue: "Downloading the update package")
        case .extracting:
            return String(localized: "update.preparingUpdate", defaultValue: "Extracting and preparing the update")
        case let .installing(install):
            guard install.isAutoUpdate else {
                return String(localized: "update.installingAndRestarting", defaultValue: "Installing update and preparing to restart")
            }
            if isRestartWhenIdleArmed {
                return String(localized: "update.restartingWhenIdle.message", defaultValue: "cmux will restart to finish updating when you step away")
            }
            return String(localized: "update.restartToComplete", defaultValue: "Restart to Complete Update")
        case .notFound:
            return String(localized: "update.noUpdates.message", defaultValue: "You are running the latest version")
        case .error(let err):
            return Self.userFacingErrorMessage(for: err.error)
        }
    }

    /// A short trailing badge (version or percent) for the current phase, or `nil`.
    public var badge: String? {
        switch effectiveState {
        case .updateAvailable(let update):
            let version = update.appcastItem.displayVersionString
            return version.isEmpty ? nil : version
        case .downloading(let download):
            if let expectedLength = download.expectedLength, expectedLength > 0 {
                let percentage = Double(download.progress) / Double(expectedLength) * 100
                return String(format: "%.0f%%", percentage)
            }
            return nil
        case .extracting(let extracting):
            return String(format: "%.0f%%", extracting.progress * 100)
        default:
            return nil
        }
    }

    /// The detected-background-update title, when one should be shown.
    var detectedUpdateText: String? {
        guard showsDetectedBackgroundUpdate, let version = detectedUpdateVersion else { return nil }
        return String(localized: "update.available.withVersion", defaultValue: "Update Available: \(version)")
    }

    /// Normalizes a Sparkle display version into a trimmed, non-empty string, or `nil`.
    public static func normalizedDetectedUpdateVersion(from version: String) -> String? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if DEBUG
/// A synthetic update-error scenario that the debug menu can inject so every error popover
/// variant (title, message, and whether the manual-download button shows) can be previewed
/// without reproducing the real failure.
///
/// Cases map one-to-one to the branches in ``UpdateStateModel/userFacingErrorTitle(for:)`` /
/// ``UpdateStateModel/userFacingErrorMessage(for:)`` / ``UpdateStateModel/manualDownloadURL(for:)``.
public enum DebugUpdateErrorScenario: String, CaseIterable, Hashable, Sendable {
    /// 4005 wrapping the internal IPC-timeout (the wedged-launchd case): "Couldn't Start Updater".
    case installerAgentFailure
    /// 4010 `SUAgentInvalidationError`: also "Couldn't Start Updater".
    case agentInvalidation
    /// Plain 4005 with no agent signal: "Updater Permission Error" + recovery message + download.
    case genericInstallFailure
    /// 4005 wrapping `SUAuthenticationFailure` (4001): must NOT be treated as an agent failure.
    case installFailureWrappingAuth
    /// 2001 `SUDownloadError`: "Couldn't Download Update", offers download.
    case downloadFailure
    /// 1003 `SURunningFromDiskImageError`: keeps "Move into Applications", no download button.
    case diskImageTranslocation
    /// 3001 `SUSignatureError`: signature copy, deliberately no download button.
    case signatureError
    /// Offline `NSURLError`: "No Internet Connection".
    case noInternet

    /// The label shown for this scenario in the debug menu.
    public var menuTitle: String {
        switch self {
        case .installerAgentFailure: return "Installer Agent Failure (4005 + timeout)"
        case .agentInvalidation: return "Agent Invalidation (4010)"
        case .genericInstallFailure: return "Generic Install Failure (4005)"
        case .installFailureWrappingAuth: return "Install Failure / Auth (4005→4001)"
        case .downloadFailure: return "Download Failure (2001)"
        case .diskImageTranslocation: return "Disk Image / Translocated (1003)"
        case .signatureError: return "Signature Error (3001)"
        case .noInternet: return "No Internet"
        }
    }

    /// Builds the synthetic error for this scenario.
    var error: NSError {
        switch self {
        case .installerAgentFailure:
            let underlying = NSError(domain: SUSparkleErrorDomain, code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Timeout: agent connection was never initiated",
            ])
            return NSError(domain: SUSparkleErrorDomain, code: 4005, userInfo: [
                NSLocalizedDescriptionKey: "An error occurred while running the updater. Please try again later.",
                NSLocalizedFailureReasonErrorKey: "The remote port connection was invalidated from the updater.",
                NSUnderlyingErrorKey: underlying,
            ])
        case .agentInvalidation:
            return NSError(domain: SUSparkleErrorDomain, code: 4010, userInfo: [
                NSLocalizedDescriptionKey: "The updater agent was invalidated.",
            ])
        case .genericInstallFailure:
            return NSError(domain: SUSparkleErrorDomain, code: 4005, userInfo: [
                NSLocalizedDescriptionKey: "The installation failed.",
            ])
        case .installFailureWrappingAuth:
            let underlying = NSError(domain: SUSparkleErrorDomain, code: 4001, userInfo: [
                NSLocalizedDescriptionKey: "Authorization failed.",
            ])
            return NSError(domain: SUSparkleErrorDomain, code: 4005, userInfo: [
                NSLocalizedDescriptionKey: "An error occurred while installing the update.",
                NSUnderlyingErrorKey: underlying,
            ])
        case .downloadFailure:
            return NSError(domain: SUSparkleErrorDomain, code: 2001, userInfo: [
                NSLocalizedDescriptionKey: "The update download failed.",
            ])
        case .diskImageTranslocation:
            return NSError(domain: SUSparkleErrorDomain, code: 1003, userInfo: [
                NSLocalizedDescriptionKey: "Running from a disk image.",
            ])
        case .signatureError:
            return NSError(domain: SUSparkleErrorDomain, code: 3001, userInfo: [
                NSLocalizedDescriptionKey: "The update signature is invalid.",
            ])
        case .noInternet:
            return NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
                NSLocalizedDescriptionKey: "The Internet connection appears to be offline.",
            ])
        }
    }
}
#endif
