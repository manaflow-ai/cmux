public import CmuxNextActions
public import CmuxNextDaemon
import CmuxNextCompat

extension DaemonService {
    /// Whether commands reach the daemon now: a connection whose link is up. `connection`
    /// alone stays set while a dropped link retries (a Cloud VM paused after it connected),
    /// and is nil only until the first connect, so it misses a drop.
    public var isLive: Bool {
        guard connection != nil, case .connected = store.connectionState else { return false }
        return true
    }

    /// ``failure(_:_:)``, after waiting for this daemon to be live when `waits`. A person's close
    /// of a workspace of a machine that is not connected (a paused Cloud VM) waits for the machine
    /// to connect again instead of failing "not connected" and listing the row again. The wait
    /// ends when `present` turns false (the machine left the app: signed out, removed), and the
    /// command then fails "not connected". Driven by observation, never by polling; a cancelled
    /// wait runs the command at once (it then fails).
    public func failureOnceConnected(_ label: String, waits: Bool, while present: @escaping @MainActor @Sendable () -> Bool,
                                     _ body: DaemonCommandBody) async -> ActionWorkFailure? {
        if waits { for await done in ObservationStream({ self.isLive || !present() }) where done { break } }
        return await failure(label, body)
    }

    /// ``failureOnceConnected(_:waits:while:_:)`` for a command whose result the caller reads from the store
    /// next (a close whose row stays hidden until the store drops it): after the reply, waits until the store
    /// applied it on the connection that answered (``appliedThroughReply(on:after:)``). When that wait does not
    /// hold, the command went through but the store cannot show it: ``ActionWorkFailure/resultNotShown``.
    public func failureOnceApplied(_ label: String, waits: Bool, while present: @escaping @MainActor @Sendable () -> Bool,
                                   _ body: DaemonCommandBody) async -> ActionWorkFailure? {
        if waits { for await done in ObservationStream({ self.isLive || !present() }) where done { break } }
        var answered: DaemonConnection?
        if let failed = await failure(label, ticket: openTicket(label), body, replied: { answered = $0 }) { return failed }
        guard let answered else { return .resultNotShown }
        return await appliedThroughReply(on: answered, after: label).isHeld ? nil : .resultNotShown
    }
}
