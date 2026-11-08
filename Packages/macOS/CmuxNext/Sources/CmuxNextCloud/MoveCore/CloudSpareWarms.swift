/// The spare warms in flight (Leo, Cloud V0 item 1: "harness login attached in advance"), with no rules of their own:
/// one warm per account and team, and each warm's login copy by its machine (Rust's copy target,
/// ``CloudMoveCLI/startChatWarmSpare(platform:account:access:install:abandoned:)``). Nothing here makes a caller wait
/// on a warm, except a start whose Rust verdict says it would race the copy on that machine.
@MainActor public final class CloudSpareWarms {
    private var warms: [String: Task<Void, Never>] = [:]
    private var copies: [String: Task<Bool, Never>] = [:]

    public init() {}

    /// Starts `work` as the warm of `identity` (``CloudAuth/accountKey``) unless that identity's warm runs, and returns
    /// at once with the warm in flight: an app activation or a composer intent never waits on it.
    @discardableResult public func start(_ identity: String, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        if let running = warms[identity] { return running }
        // task-owner: this, until `work` ends; each of its calls has its own timeout.
        let warm = Task { @MainActor [weak self] in
            await work()
            self?.warms[identity] = nil
        }
        warms[identity] = warm
        return warm
    }

    /// Whether `identity`'s warm is in flight.
    public func isWarming(_ identity: String) -> Bool { warms[identity] != nil }

    /// Runs a warm's login copy onto `machine`, tracked by it until it ends; answers whether a login was installed.
    public func copy(onto machine: String, _ work: @escaping @MainActor () async -> Bool) -> Task<Bool, Never> {
        // task-owner: this, until `work` ends (the copy's own timeouts).
        let copy = Task { @MainActor [weak self] in
            let installed = await work()
            self?.copies[machine] = nil
            return installed
        }
        copies[machine] = copy
        return copy
    }

    /// Whether a warm's login copy onto `machine` is in flight.
    public func isCopying(_ machine: String) -> Bool { copies[machine] != nil }

    /// Waits for the warm's copy onto `machine` only when the start `conflicts` with it (Rust's `warmCopyConflict`);
    /// any other start, and a start on any other machine, returns at once.
    public func waitForCopy(onto machine: String, conflicts: Bool) async {
        guard conflicts, let copy = copies[machine] else { return }
        _ = await copy.value
    }
}
