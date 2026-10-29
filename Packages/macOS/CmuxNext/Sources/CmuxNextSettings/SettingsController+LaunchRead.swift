public import CmuxNextDesignTokens
public import CmuxNextWakeups
public import Foundation

extension SettingsController {
    /// The launch's first load, read before the controller exists so the
    /// terminal runtime starts in the file's appearance; the controller
    /// adopts it (`init(launch:)`) instead of reading the file again.
    public nonisolated struct LaunchRead: Sendable {
        let loaded: Loaded
        public let fileURL: URL
        /// Why first launch could not make the file (`CmuxConfigFile.prepareDefaultURL`), so the read
        /// used the default path; nil when it was made or already existed.
        public let bootstrapFailure: String?
        public var snapshot: CmuxConfigSnapshot { loaded.snapshot }
    }

    /// Starts the launch's read on `work`'s files lane, from `main()` while AppKit starts (p08-startup
    /// 025; Chrome reads the profile's preferences on a blocking sequence before the first window,
    /// chrome/browser/prefs/chrome_pref_service_factory.cc): first-launch file creation, the file read,
    /// the parse and the managed layers all run there, never on the main thread.
    ///
    /// - Parameters:
    ///   - work: The app's blocking-work lanes.
    ///   - sequence: The sequence the read runs in, after what was posted to it before (the app: the incognito
    ///     ledger read, which the launch window built on this read's landing needs); nil runs it on `work`'s
    ///     files lane beside the other launch reads.
    ///   - prepareFileURL: Makes the settings file on first launch and returns its URL; runs on the lane.
    ///   - fallbackURL: The file read when `prepareFileURL` throws.
    ///   - managedReader: The managed (MDM) preferences; read on the lane.
    /// - Returns: The read in flight; ``PendingLaunchRead/whenRead(on:_:)`` hands it to the steps that need it.
    public static func startLaunchRead(
        on work: BackgroundWork,
        in sequence: WorkSequence? = nil,
        prepareFileURL: @escaping @Sendable () throws -> URL = { try CmuxConfigFile.prepareDefaultURL() },
        fallbackURL: @escaping @Sendable () -> URL = { CmuxConfigFile.defaultURL() },
        managedReader: any ManagedPreferenceReader = ManagedPreferenceLocation.defaultReader()
    ) -> PendingLaunchRead {
        let valid = validValues
        let read: @Sendable () -> LaunchRead = {
            let prepared = Result { try prepareFileURL() }
            let fileURL = (try? prepared.get()) ?? fallbackURL()
            var failure: String?
            if case .failure(let error) = prepared { failure = String(describing: error) }
            let source = Result { try CmuxConfigFile.source(at: fileURL) }
            let loaded = SettingsController.loaded(source, managed: managedReader.read(), team: .none, lastGood: .object([:]), valid: valid,
                                                   configDirectory: fileURL.deletingLastPathComponent())
            return LaunchRead(loaded: loaded, fileURL: fileURL, bootstrapFailure: failure)
        }
        let pending = sequence.map { CmuxNextWakeups.LaunchRead(in: $0, read) } ?? CmuxNextWakeups.LaunchRead(on: work, read)
        return PendingLaunchRead(work: work, read: pending)
    }

    /// The settings launch read in flight (``startLaunchRead(on:in:prepareFileURL:fallbackURL:managedReader:)``).
    ///
    /// The launch steps that need it run in a continuation on its completion: never a wait on the main
    /// thread, and never a frame in the defaults first (a value-or-nil take has no correct default).
    ///
    /// ```swift
    /// let settingsRead = SettingsController.startLaunchRead(on: work)    // main(), before NSApp.run
    /// settingsRead.whenRead(hop: .userVisible, startup: order.startup,   // applicationDidFinishLaunching
    ///                       take: { TerminalThemeSetting.prime($0.snapshot) }, then: { finishLaunching($0) })
    /// ```
    public nonisolated struct PendingLaunchRead: Sendable {
        let work: BackgroundWork
        let read: CmuxNextWakeups.LaunchRead<LaunchRead>

        /// The result once the read has ended; nil while it runs.
        public var value: LaunchRead? { read.value }

        /// Takes the read, then runs the launch steps that need it, on the main thread, never waiting:
        /// at once, in this turn, when the read has ended (a warm launch); else on its completion, in
        /// the next main turn through `hop`, the startup's main hop (unbudgeted, as
        /// `applicationDidFinishLaunching`'s own turn: no frame budget, no class queue, no owner but
        /// the steps' own).
        ///
        /// `take` runs first, as `startup`'s critical `Settings.takeLaunchRead` step (its record,
        /// signpost and the watchdog's task name), then `then` in the same turn: no step that needs
        /// the settings, and so no window commit, comes before the take.
        ///
        /// - Parameters:
        ///   - hop: How the continuation reaches main once the read ends off main (the app: ``StartupMainHop/userVisible``).
        ///   - startup: The launch's scheduler; `take` is its `Settings.takeLaunchRead` step.
        ///   - take: Applies what the first frame needs from the read (the Ghostty overrides).
        ///   - then: The rest of the launch, with the read.
        @MainActor
        public func whenRead(hop: StartupMainHop, startup: StartupScheduler,
                             take: @escaping @MainActor @Sendable (LaunchRead) -> Void,
                             then: @escaping @MainActor @Sendable (LaunchRead) -> Void) {
            let run: @MainActor @Sendable (LaunchRead) -> Void = { value in
                startup.post(.critical, "Settings.takeLaunchRead", on: .main) { take(value) }
                then(value)
            }
            if let value = read.value { return run(value) }
            let read = read
            work.task(.userBlocking) {
                let value = await read.finished()
                hop.later { run(value) }
            }
        }
    }
}
