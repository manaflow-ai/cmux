public import CmuxUpdater
public import Foundation
import Observation

/// cmux-next's updater. Release builds (stable, NIGHTLY, RC) run the shared
/// Sparkle driver (`CmuxUpdater.UpdateController`: automatic checks from
/// the existing `SU*` defaults, launch probe, install watchdog, re-resolve
/// before install). DEV/staging builds never run Sparkle; their checks are
/// a read-only probe of the same feed.
///
/// One per process, owned by the App. Action handlers call ``checkForUpdates()``,
/// ``installAvailableUpdate()`` and ``switchChannel(to:)``. Nothing asks: updates
/// download in the background and wait as the rail's update circle
/// (``indicatorPhase``), and a check that finds nothing leaves a short note.
/// The update sheet (``UpdateSheetModel``) opens only for a failure's details.
@MainActor
@Observable
public final class UpdaterService {
    public let identity: UpdateBuildIdentity
    public let log: UpdateLogBuffer
    /// The Sparkle driver; nil when Sparkle cannot run in this build.
    public let controller: UpdateController?
    public private(set) var lastProbe: UpdateProbeResult?
    public private(set) var lastProbeError: String?
    public private(set) var isProbing = false
    /// The running stable <-> NIGHTLY switch, if any.
    public private(set) var channelSwitchPhase: AppChannelSwitchPhase?
    public private(set) var channelSwitchError: String?
    /// `UpdateChannel` from the managed policy, or nil.
    public internal(set) var managedChannel: AppChannelSwitchTarget?
    /// `MinimumVersion` from the managed policy, or nil.
    public internal(set) var managedMinimumVersion: String?
    /// Whether the circle shows the last probe's result (the user asked, in a
    /// build without Sparkle).
    public internal(set) var showsProbeResult = false
    /// A fixed circle phase for screenshots (`debug.update_indicator`).
    public var debugIndicatorPhase: UpdateIndicatorPhase?
    /// The R114 install gate over ``indicatorPhase``.
    public internal(set) var flow = UpdateFlow()
    /// The `updates.*` settings the gate reads (set by the App).
    public var preferences = UpdatePreferences.defaults
    /// The local minute of the day the card is evaluated at.
    public internal(set) var minuteOfDay = 0
    /// Asks the App to confirm an install although agents run (CmuxDialog).
    @ObservationIgnored public var confirmInterrupt: ((UpdateBlockers) -> Void)?
    /// Sparkle's staged install and its cancel (replaced by tests).
    @ObservationIgnored var installStaged: () -> Void = {}
    @ObservationIgnored var cancelStaged: () -> Void = {}

    /// Asks the App to show the update sheet (set by the App): a failure's
    /// details only.
    @ObservationIgnored public var presentUpdateUI: (() -> Void)?
    /// Sparkle is about to relaunch into the update (set by the App: the quit
    /// keeps every terminal).
    @ObservationIgnored public var willRelaunch: (() -> Void)?
    /// Whether a window shows the rail's update circle (set by the App:
    /// false while the window rail is off). Without it, checks and installs
    /// open the update sheet.
    @ObservationIgnored public var showsIndicator: () -> Bool = { true }
    /// Whether the update sheet is on screen (set by the App): a note's
    /// timeout then leaves the state alone so the sheet keeps its details.
    @ObservationIgnored public var isSheetPresented: () -> Bool = { false }
    @ObservationIgnored private let policy: ManagedUpdatePolicy
    @ObservationIgnored private let prober: UpdateProber
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let switcher: AppChannelSwitcher
    @ObservationIgnored private var probeTask: Task<String?, Never>?
    @ObservationIgnored private var switchTask: Task<String?, Never>?
    @ObservationIgnored private var started = false
    /// Whether ``start()`` ran (the managed policy checks only after it).
    var isStarted: Bool { started }

    /// - Parameter enableSparkle: false builds no Sparkle driver even for a
    ///   release identity (tests, demos).
    public init(identity: UpdateBuildIdentity = .main(),
                policy: ManagedUpdatePolicy = .live(),
                prober: UpdateProber = UpdateProber(),
                defaults: UserDefaults = .standard,
                switcher: AppChannelSwitcher = AppChannelSwitcher(),
                enableSparkle: Bool = true) {
        self.identity = identity
        self.policy = policy
        self.prober = prober
        self.defaults = defaults
        self.switcher = switcher
        let log = UpdateLogBuffer()
        self.log = log
        // The managed policy is re-read by the driver on every start and check,
        // so it is not a reason to skip building it.
        if enableSparkle, identity.sparkleDisabledReason(managedPolicyDisablesUpdates: false) == nil {
            let controller = UpdateController(log: log, defaults: defaults, isDisabledByPolicy: { policy.disablesUpdates })
            // Never prompt: download in the background and wait for a click.
            // Set on this updater only; no defaults change, so the legacy app
            // sharing the domain keeps its own behavior.
            controller.installsUpdatesInBackground = true
            self.controller = controller
        } else {
            controller = nil
        }
    }

    /// Why Sparkle does not run right now, or nil.
    public var disabledReason: UpdateDisabledReason? {
        if controller == nil, let reason = identity.sparkleDisabledReason(managedPolicyDisablesUpdates: policy.disablesUpdates) {
            return reason
        }
        return policy.disablesUpdates ? .managedPolicy : nil
    }

    /// Starts Sparkle (scheduled checks and the launch probe honor
    /// `SUEnableAutomaticChecks`). Idempotent; no-op without a driver.
    public func start() {
        guard !started else { return }
        started = true
        guard let controller else {
            log.append("sparkle not started (\(disabledReason?.rawValue ?? "no driver"), track=\(identity.track.rawValue))")
            return
        }
        controller.actionDelegate = self
        controller.startUpdaterIfNeeded()
        recheckRequiredUpdate()
    }

    /// The user asked to check. With Sparkle it starts a foreground Sparkle
    /// check (a found update downloads, no sheet), else a read-only probe
    /// whose result the circle notes (never under a managed policy, which
    /// forbids touching the feed). The returned task finishes when a probe
    /// has its result (nil) or failed (the reason).
    @discardableResult
    public func checkForUpdates() -> Task<String?, Never>? {
        if needsSheet { presentUpdateUI?() }
        switch disabledReason {
        case .managedPolicy:
            log.append("check suppressed (managed policy)")
            return nil
        case nil:
            guard let controller else { return nil }
            controller.model.setOverrideState(nil)
            controller.checkForUpdates()
            return nil
        case .developmentBuild, .missingPublicKey:
            showsProbeResult = true
            return probe()
        }
    }

    /// Reads the feed and records what it offers this Mac. Joins a probe
    /// already in flight.
    @discardableResult
    public func probe() -> Task<String?, Never> {
        if let probeTask { return probeTask }
        isProbing = true
        let prober = prober, identity = identity
        let task = Task { [weak self] () -> String? in
            let failure: String?
            do {
                let result = try await prober.probe(identity)
                self?.lastProbe = result
                self?.lastProbeError = nil
                self?.log.append("probe \(result.outcome.kind) feed=\(result.feedURL) items=\(result.itemCount)")
                failure = nil
            } catch {
                let reason = String(describing: error)
                self?.lastProbeError = reason
                self?.log.append("probe failed: \(reason)")
                failure = reason
            }
            self?.isProbing = false
            self?.probeTask = nil
            return failure
        }
        probeTask = task
        return task
    }

    /// Installs and relaunches: the downloaded update at once, the one
    /// downloading as soon as it is ready, else the newest after a fresh
    /// check (the shared driver's attempt flow, so never a stale version).
    public func installAvailableUpdate() throws {
        guard let controller, disabledReason == nil else { throw UpdaterUnavailable(reason: disabledReason) }
        if needsSheet { presentUpdateUI?() }
        controller.model.setOverrideState(nil)
        if controller.stagedUpdate != nil { return controller.installStagedUpdate() }
        controller.installWhenStaged()
        switch controller.model.state {
        case .startingDownload, .downloading, .extracting: return
        default: controller.attemptUpdate()
        }
    }

    /// Opens the other release app (stable <-> NIGHTLY), downloading,
    /// verifying and installing it first when missing. Both apps coexist.
    @discardableResult
    public func switchChannel(to target: AppChannelSwitchTarget) throws -> Task<String?, Never> {
        guard identity.channelSwitchTarget == target else { throw UpdaterUnavailable.cannotSwitch(to: target, from: identity.track) }
        if policy.disablesUpdates { throw UpdaterUnavailable(reason: .managedPolicy) }
        if let refusal = managedChannelRefusal(target) { throw refusal }
        if let switchTask { return switchTask }
        channelSwitchError = nil
        let switcher = switcher
        let task = Task { [weak self] () -> String? in
            var failure: String?
            do {
                let outcome = try await switcher.switchTo(target) { phase in
                    Task { @MainActor in self?.channelSwitchPhase = phase }
                }
                self?.log.append("channel switch to \(target.rawValue): \(outcome)")
            } catch {
                failure = String(describing: error)
                self?.channelSwitchError = failure
                self?.log.append("channel switch to \(target.rawValue) failed: \(failure ?? "")")
            }
            self?.channelSwitchPhase = nil
            self?.switchTask = nil
            return failure
        }
        switchTask = task
        return task
    }

    public var status: UpdaterStatus {
        let reason = disabledReason
        let state = controller?.model.effectiveState ?? .idle
        return UpdaterStatus(
            track: identity.track,
            bundleIdentifier: identity.bundleIdentifier,
            version: identity.shortVersion,
            build: identity.build,
            minimumSystemVersion: identity.minimumSystemVersion,
            system: .current,
            feedURL: identity.feed().url,
            sparkleDisabledReason: reason,
            automaticChecks: reason == nil && bool(UpdateSettings.automaticChecksKey, fallback: true),
            automaticDownloads: reason == nil && bool(UpdateSettings.automaticallyUpdateKey, fallback: false),
            phase: UpdatePhase(state),
            detectedVersion: controller?.model.detectedUpdateVersion,
            probing: isProbing,
            lastProbe: lastProbe,
            lastProbeError: lastProbeError,
            channelSwitchTarget: identity.channelSwitchTarget
        )
    }

    private func bool(_ key: String, fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? (Bundle.main.object(forInfoDictionaryKey: key) as? Bool) ?? fallback
    }
}

extension UpdaterService: UpdateActionDelegate {
    public func updaterRequestsRetryCheckForUpdates() {
        checkForUpdates()
    }

    /// Nothing to save: terminals and layout live in the cmux-tui daemon and
    /// survive the relaunch. Sparkle's terminate goes through the normal
    /// `applicationShouldTerminate` path.
    public func updaterWillRelaunchApplication() {
        log.append("relaunching for update")
        willRelaunch?()
    }

    /// A relaunch interrupts nothing (the daemon keeps every terminal and
    /// agent running), so a ready update is never held.
    public func updaterRelaunchBlockers() -> UpdateRelaunchBlockers {
        .empty
    }
}

extension UpdaterService {
    /// ``switchChannel(to:)`` by name (`stable`, `nightly`); nil means the
    /// counterpart of the running app.
    @discardableResult
    public func switchChannel(named name: String?) throws -> Task<String?, Never> {
        let requested = name.flatMap { AppChannelSwitchTarget(rawValue: $0.lowercased()) }
        guard let target = requested ?? identity.channelSwitchTarget, name == nil || requested != nil else {
            throw UpdaterUnavailable.cannotSwitch(to: name ?? "?", from: identity.track)
        }
        return try switchChannel(to: target)
    }

    /// Why switching channels is impossible here (DEV/RC builds have no
    /// counterpart), or nil.
    public var channelSwitchUnavailableReason: String? {
        guard let target = identity.channelSwitchTarget else {
            return UpdaterUnavailable.cannotSwitch(to: "stable/nightly", from: identity.track).description
        }
        return managedChannelRefusal(target)?.description
    }

    /// Why installing is impossible here, or nil.
    public var installUnavailableReason: String? {
        controller != nil && disabledReason == nil ? nil : UpdaterUnavailable(reason: disabledReason).description
    }
}
