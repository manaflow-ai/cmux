public import Observation

/// The iOS simulator setup flow behind the phone tab's setup screen: the
/// current step, the running download or create, and the last failure in
/// plain words. One per app (owned by ``PhoneService``), so every phone tab
/// shows the same progress and a download keeps going when a tab closes.
@MainActor @Observable
public final class PhoneSetupCoordinator {
    /// The last check's answer; nil before the first check (and when setup checks are off).
    public private(set) var status: PhoneSetupStatus?
    /// The step running now, if any.
    public private(set) var activity: PhoneSetupActivity?
    /// The last step's failure, as ``PhoneErrorText`` words; cleared when a step starts.
    public private(set) var failure: PhoneErrorText?

    private let check: PhoneSetupCheck?
    private var download: Task<Void, Never>?

    /// - Parameter check: nil turns setup off (tests, platforms without simulators).
    public init(check: PhoneSetupCheck?) {
        self.check = check
    }

    /// True when the setup flow can run on this Mac.
    public var isAvailable: Bool { check != nil }

    /// Checks this Mac again and returns the step it needs. Safe to call any
    /// time; a running download or create keeps its own activity.
    @discardableResult
    public func refresh() async -> PhoneSetupStep? {
        guard let check else { return nil }
        if activity == nil { activity = .checking }
        let found = await check.status()
        status = found
        if activity == .checking { activity = nil }
        return found.step
    }

    /// Starts downloading the iOS runtime; progress shows in ``activity``. Checks again when it ends.
    public func downloadIOS() {
        guard let check, download == nil else { return }
        failure = nil
        activity = .downloading(PhoneSetupProgress())
        // task-owner: the coordinator; ``cancelDownload()`` cancels it, which interrupts xcodebuild.
        download = Task { [weak self] in
            do {
                try await check.downloadIOS { progress in self?.activity = .downloading(progress) }
            } catch is CancellationError {
            } catch {
                self?.failure = PhoneErrorText(error)
            }
            self?.activity = nil
            self?.download = nil
            await self?.refresh()
        }
    }

    /// Stops a running download.
    public func cancelDownload() {
        download?.cancel()
    }

    /// Creates the suggested iPhone and returns it (nil after a failure, which ``failure`` explains).
    public func createIPhone() async -> PhoneDeviceID? {
        guard let check, activity == nil || activity == .checking else { return nil }
        failure = nil
        activity = .creating
        defer { activity = nil }
        do {
            let made = try await check.createIPhone()
            status?.step = .ready
            return made
        } catch {
            failure = PhoneErrorText(error)
            return nil
        }
    }

    /// Shows `error` as the setup screen's failure (a step the tab ran itself, such as booting the new iPhone).
    public func report(_ error: any Error) {
        failure = PhoneErrorText(error)
    }
}
