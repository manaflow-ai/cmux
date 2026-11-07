import CmuxNextCompat
import CmuxNextDaemon
public import CmuxNextSettings
public import Foundation
import os

/// Where `cmux usage upload` sends and as whom: the platform of the selected Cloud backend and a
/// fresh install token of the signed-in person. Handed to the CLI on stdin, never in argv.
public struct UsageShareAccess: Sendable, Equatable {
    public var platform: URL
    public var credential: String

    public init(platform: URL, credential: String) {
        self.platform = platform
        self.credential = credential
    }
}

/// Opt-in team usage sharing, the second opt-in on top of usage recording (Leo 2026-11-07: "could
/// we opt in to tracking usage patterns? at least for myself ... and likewise for the rest of the
/// team"): follows `diagnostics.usageSharing`, switches the daemon's `share` marker
/// (`usage-set-sharing`), and runs the bundled `cmux usage upload` now and then. Every rule of
/// what goes and how far it got is Rust (cmux-usage `share`, cmux-tui `cli/usage_sharing.rs`);
/// this only decides when.
///
/// It shares only while recording is on (the daemon answered the recording switch) and with the
/// setting on and this Mac's own consent record, which only the person's write of the setting or
/// the confirm card's yes sets, as for recording: cmux-next.json syncs between Macs and agents can
/// edit it. A file that turns it on without the record asks once per launch; never an invitation.
///
/// When: once the daemon answered the share switch (at launch), and when the app resigns active,
/// at most once per ``uploadInterval`` (the last try is kept in this Mac's defaults, so a failing
/// upload is not retried sooner). No timer, no observer of its own besides the setting. Each upload
/// is one child process with a deadline (``uploadDeadline``), off the main actor.
@MainActor
public final class UsageSharing {
    /// This Mac's consent record: the time of the person's own yes. Turning sharing off removes it.
    public static let consentKey = "cmux.next.usageSharing.consentedAt"
    /// When this Mac last started an upload.
    public static let lastUploadKey = "cmux.next.usageSharing.lastUploadAt"
    /// The shortest time between two uploads.
    public static let uploadInterval: TimeInterval = 6 * 60 * 60
    /// The longest one `cmux usage upload` may run (each of its calls has a 30 s deadline).
    nonisolated static let uploadDeadline: Duration = .seconds(300)

    /// What sharing reaches outside itself.
    struct Ports {
        /// The confirm card (title, detail, yes, no): true for yes.
        var ask: @MainActor (String, String, String, String) async -> Bool
        /// `usage-set-sharing`.
        var setSharing: @Sendable (Bool) async throws -> Void
        /// One `cmux usage upload`: true when it sent everything.
        var upload: @Sendable () async -> Bool
        /// The time now.
        var now: @MainActor () -> Date = { Date() }
    }

    /// What to do with the settings and this Mac's records.
    public enum Decision: Sendable, Hashable {
        /// Share.
        case share
        /// Recording is on and the setting too, but this Mac never agreed to share: ask.
        case confirm
        /// Share nothing, ask nothing.
        case off
    }

    private let ports: Ports
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "usage-sharing")
    private var settingsObservation: Task<Void, Never>?
    private weak var settings: SettingsController?
    private var firstWindow: (@MainActor () async -> Void)?
    private var settingOn = false
    /// Recording is on: the daemon answered its switch-on, and nothing switched it off since.
    private var recordingOn = false
    /// The daemon's share marker as last answered; nil before the first switch.
    private var switchSent: Bool?
    /// The last switch sent and its value; each waits for the one before, so the daemon sees them
    /// in order.
    private var switchTask: Task<Void, Never>?
    private var switchPending: Bool?
    private var switchGeneration = 0
    private var askedThisLaunch = false
    private var uploading = false

    init(ports: Ports, defaults: UserDefaults) {
        self.ports = ports
        self.defaults = defaults
    }

    /// The decision now.
    public var decision: Decision {
        Self.decision(recordingOn: recordingOn, settingOn: settingOn, consented: Self.consented(defaults))
    }

    /// Follows the setting from the first load on, and records this Mac's consent from the
    /// person's own writes of it.
    func start(settings: SettingsController, isFirstLaunch: Bool, firstWindow: @escaping @MainActor () async -> Void) {
        if isFirstLaunch { askedThisLaunch = true }
        self.settings = settings
        self.firstWindow = firstWindow
        settings.chainUserWillWrite { [defaults] descriptor, value in
            Self.recordUserWrite(defaults: defaults, path: descriptor.path, value: value)
        }
        // task-owner: follows the setting for the life of the process (with the recorder that owns it).
        settingsObservation = Task { [weak self, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await on in ObservationStream({ settings.snapshot.usageSharing }) {
                guard let self else { return }
                setting(on)
            }
        }
    }

    /// The setting's value now. Off removes this Mac's consent, so a file that turns it on again
    /// needs a new yes.
    func setting(_ on: Bool) {
        if !on { defaults.removeObject(forKey: Self.consentKey) }
        settingOn = on
        follow()
    }

    /// Recording went on (its switch answered) or off.
    func recording(_ on: Bool) {
        guard recordingOn != on else { return }
        recordingOn = on
        follow()
    }

    /// The app resigned active: an upload when one is due.
    func appResigned() {
        uploadIfDue()
    }

    private func follow() {
        let decision = decision
        apply(decision == .share)
        guard decision == .confirm, !askedThisLaunch, let settings, let firstWindow else { return }
        askedThisLaunch = true
        // task-owner: one question after the first frame; it ends when the person answers.
        Task { [weak self] in
            await firstWindow()
            await self?.ask(settings: settings)
        }
    }

    /// The confirm card. Only Share Usage records consent.
    private func ask(settings: SettingsController) async {
        guard decision == .confirm else { return }
        let yes = await ports.ask(Strings.askTitle, Self.privacySummary, Strings.askYes, Strings.askNo)
        // The file (or recording) may have turned it off while the card was up.
        guard yes, settings.snapshot.usageSharing, recordingOn else { return }
        defaults.set(Date(), forKey: Self.consentKey)
        follow()
    }

    /// The daemon's share marker on or off, after the switch before it; on, once answered,
    /// uploads when due. A switch the daemon did not answer is not counted, so the next decision
    /// sends it again.
    func apply(_ on: Bool) {
        guard (switchPending ?? switchSent) != on else { return }
        switchPending = on
        switchGeneration += 1
        let generation = switchGeneration
        let previous = switchTask
        let setSharing = ports.setSharing
        let logger = logger
        // task-owner: one switch of the daemon's marker after the previous one; ends when the daemon answers.
        switchTask = Task { [weak self] in
            await previous?.value
            let ok: Bool
            do {
                try await setSharing(on)
                ok = true
            } catch {
                logger.error("usage-set-sharing \(on) failed: \(String(describing: error), privacy: .public)")
                ok = false
            }
            self?.switched(on, ok: ok, generation: generation)
        }
    }

    private func switched(_ on: Bool, ok: Bool, generation: Int) {
        if ok { switchSent = on }
        // Only the last switch sent ends the chain; an earlier one is followed by it.
        guard generation == switchGeneration else { return }
        switchPending = nil
        switchTask = nil
        if ok, on { uploadIfDue() }
    }

    /// Starts one upload when sharing is on, the daemon holds the marker, none runs and the last
    /// one started at least ``uploadInterval`` ago.
    func uploadIfDue() {
        let now = ports.now()
        guard decision == .share, switchSent == true, !uploading,
              Self.uploadDue(now: now, last: defaults.object(forKey: Self.lastUploadKey) as? Date)
        else { return }
        defaults.set(now, forKey: Self.lastUploadKey)
        uploading = true
        let upload = ports.upload
        // task-owner: one `cmux usage upload`, bounded by its own deadline (uploadDeadline).
        Task { [weak self] in
            let ok = await upload()
            self?.uploading = false
            if !ok { self?.logger.notice("usage upload did not finish; the next one is due in 6 hours") }
        }
    }

    /// Whether an upload is running (tests).
    var isUploading: Bool { uploading }

    // MARK: Rules

    /// Share with recording on, the setting on and this Mac's consent; ask with recording and the
    /// setting on and no consent; else nothing (never an invitation).
    ///
    /// - Parameters:
    ///   - recordingOn: Usage recording is on (its own setting and consent, and its switch answered).
    ///   - settingOn: `diagnostics.usageSharing` is on in the file.
    ///   - consented: This Mac holds the person's consent record to share.
    /// - Returns: The decision.
    public static func decision(recordingOn: Bool, settingOn: Bool, consented: Bool) -> Decision {
        guard recordingOn, settingOn else { return .off }
        return consented ? .share : .confirm
    }

    /// Whether an upload is due at `now` after one started at `last`: none yet, ``uploadInterval``
    /// passed, or the clock went back past it.
    public static func uploadDue(now: Date, last: Date?, interval: TimeInterval = uploadInterval) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= interval || elapsed < 0
    }

    /// This Mac holds the person's consent record to share.
    public static func consented(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: consentKey) is Date }

    /// The person's own write of `path` (`SettingsController.userWillWrite`): `true` for the
    /// sharing setting records this Mac's consent; any other value removes it. Returns the undo.
    ///
    /// - Parameters:
    ///   - defaults: Where the record lives.
    ///   - path: The written key path.
    ///   - value: The written value (nil: removed).
    /// - Returns: The undo of the record, or nil.
    public static func recordUserWrite(defaults: UserDefaults, path: [String], value: CmuxNextSettings.JSONValue?) -> (@MainActor () -> Void)? {
        guard path == UsageSharingSetting.path else { return nil }
        guard value == .bool(true) else {
            defaults.removeObject(forKey: consentKey)
            return nil
        }
        let previous = defaults.object(forKey: consentKey) as? Date
        defaults.set(Date(), forKey: consentKey)
        return { [defaults] in
            if let previous { defaults.set(previous, forKey: consentKey) } else { defaults.removeObject(forKey: consentKey) }
        }
    }

    /// Runs `cmux usage upload --credential-stdin --json` with `access` on stdin, off the main
    /// actor and within ``uploadDeadline``: true when it exited 0.
    nonisolated static func runUpload(cli: URL, access: UsageShareAccess) async -> Bool {
        let envelope = ["platform": access.platform.absoluteString, "credential": access.credential]
        guard let stdin = try? JSONSerialization.data(withJSONObject: envelope) else { return false }
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "usage-sharing")
        do {
            let result = try await ProcessRunner.run(executable: cli, arguments: ["usage", "upload", "--credential-stdin", "--json"],
                                                     environment: nil, stdin: stdin, timeout: uploadDeadline,
                                                     outputTailBytes: 4096, clock: ContinuousClock())
            // The answer is counts and a code, never the token.
            let answer = String(decoding: result.status == 0 ? result.stdout : result.stderr, as: UTF8.self)
            logger.info("cmux usage upload exited \(result.status): \(answer, privacy: .public)")
            return result.status == 0
        } catch {
            logger.error("cmux usage upload did not run: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// The card's privacy summary of a usage setting turned on (recording or sharing), for the
    /// sheet that confirms the person's own write of it; nil for any other key path.
    public static func privacySummary(forPath path: [String]) -> String? {
        switch path {
        case UsageRecordingSetting.path: UsageRecorder.privacySummary
        case UsageSharingSetting.path: privacySummary
        default: nil
        }
    }

    /// What sharing sends and to whom: the card's detail, and the confirmation sheet of
    /// `cmux settings set diagnostics.usageSharing true --confirm` (both record consent).
    public static var privacySummary: String {
        String(localized: "usageSharing.privacySummary",
               defaultValue: "cmux sends this Mac's usage record to your cmux team about every six hours: which surfaces you use, which commands run and how, their timings, and counts of open windows, panes and tabs. It never holds file names, paths, web addresses, titles, terminal or chat text, or anything you type. Run cmux usage delete-shared to delete what you shared.",
               bundle: .module)
    }

    /// The confirm card's texts (Localizable.xcstrings).
    private enum Strings {
        static var askTitle: String {
            String(localized: "usageSharing.ask.title", defaultValue: "Share Usage with Your Team?", bundle: .module)
        }

        static var askYes: String {
            String(localized: "usageSharing.ask.yes", defaultValue: "Share Usage", bundle: .module)
        }

        static var askNo: String {
            String(localized: "usageSharing.ask.no", defaultValue: "Not Now", bundle: .module)
        }
    }
}
