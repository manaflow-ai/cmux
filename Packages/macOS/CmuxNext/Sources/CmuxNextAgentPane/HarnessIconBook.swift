public import CmuxNextDaemon
public import Foundation
public import Observation

/// Every harness's icon for the native surfaces (user 12922): the `iconSpec`s of this Mac's acpmux
/// `_acpmux/harnesses`, read once acpmux answers and again on each `_acpmux/harnesses_changed`.
/// The tab strip and sidebar read ``icons`` (through `HarnessIconArtwork`), so a profile's new
/// icon shows on them as the daemon announces it.
///
/// ```swift
/// let book = HarnessIconBook(environment: { QuitAgents.environment(services) })
/// book.start()
/// ```
@MainActor
@Observable
public final class HarnessIconBook {
    /// The icons of the last reply; ``HarnessIcons/none`` until acpmux answered.
    public private(set) var icons: HarnessIcons = .none

    @ObservationIgnored private let environment: @MainActor () -> AcpmuxEnvironment?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// - Parameters:
    ///   - environment: This Mac's acpmux, or nil while it is not known yet.
    ///   - clock: The reconnect delay's clock (tests pass their own).
    public init(environment: @escaping @MainActor () -> AcpmuxEnvironment?, clock: any Clock<Duration> = ContinuousClock()) {
        self.environment = environment
        self.clock = clock
    }

    /// Starts reading and following the harness list; a second call does nothing.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.follow() }
    }

    /// Stops following the list (the app quits).
    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Takes the icons of one `_acpmux/harnesses` reply; observers hear only a change.
    /// - Parameter reply: The decoded reply.
    public func apply(harnessesReply reply: [String: Any]) {
        let next = HarnessIcons(harnessesReply: reply)
        if next != icons { icons = next }
    }

    private func follow() async {
        var delay: Duration = .seconds(1)
        // wakeup-allow: each pass awaits the daemon's watch (event-driven) or the bounded reconnect delay below
        while !Task.isCancelled {
            if let environment = environment(), await refresh(environment) {
                delay = .seconds(1)
                for await _ in Self.changes(environment) {
                    _ = await refresh(environment)
                }
            }
            // wakeup-allow: a bounded reconnect delay (1 s doubling to 30 s) after acpmux was not up
            // yet or closed the watch (a restart); the loop's Task is cancelled by stop().
            do { try await clock.sleep(for: delay) } catch { return }
            delay = min(delay * 2, .seconds(30))
        }
    }

    private func refresh(_ environment: AcpmuxEnvironment) async -> Bool {
        guard let data = try? await environment.harness(.list),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        apply(harnessesReply: reply)
        return true
    }

    /// Each `_acpmux/harnesses_changed`, until the daemon closes the watch.
    private static func changes(_ environment: AcpmuxEnvironment) -> AsyncStream<Void> {
        // One pending change is enough: each refresh reads the whole list.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let watch = environment.watchHarnesses { continuation.yield() }
            let ended = Task { await watch.value; continuation.finish() }
            continuation.onTermination = { _ in watch.cancel(); ended.cancel() }
        }
    }
}
