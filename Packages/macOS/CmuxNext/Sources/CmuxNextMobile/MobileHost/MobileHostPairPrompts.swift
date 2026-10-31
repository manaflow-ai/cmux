public import Foundation

/// The pairing requests waiting for the person, kept small against a flood (cmux-next-ios audit M4).
///
/// - A phone that asks again while its request waits adds nothing (one pending request each).
/// - At most ``limit`` phones wait at once; more are counted as blocked, never prompted.
/// - After the person answers Don't Allow, no prompt for this account shows for
///   ``quietPeriod``: new phones are counted as blocked (Settings > Mobile shows the count).
///   Requests already waiting stay in Settings, where the person can still answer them.
///
/// A pure value per signed-in account: the iPhone host resets it when the account changes.
public struct MobileHostPairPrompts: Sendable, Equatable {
    /// How long Don't Allow quiets this account's prompts.
    public static let quietPeriod: TimeInterval = 10 * 60
    /// The most phones that wait for an answer at once.
    public static let limit = 4

    /// What a request does.
    public enum Outcome: Sendable, Equatable {
        /// A new request: tell the person (notification, Dock) and show its prompt.
        case ask
        /// Already waiting (the phone retried): nothing new to show.
        case repeated
        /// Dropped: quiet after a Don't Allow, or too many waiting. Counted in ``blocked``.
        case blocked
    }

    /// The waiting requests, oldest first; the prompt shows the first.
    public private(set) var pending: [MobileHostPairRequest] = []
    /// Requests dropped since the account signed in.
    public private(set) var blocked = 0
    /// Until when prompts stay quiet after a Don't Allow; nil when they are not quiet.
    public private(set) var quietUntil: Date?

    public init() {}

    /// Whether a Don't Allow still quiets prompts at `now`.
    public func isQuiet(at now: Date) -> Bool {
        quietUntil.map { now < $0 } ?? false
    }

    /// The waiting request of phone `id`.
    public func request(id: String) -> MobileHostPairRequest? {
        pending.first { $0.phoneDeviceID == id }
    }

    /// A phone asked. A request with new keys from a waiting phone replaces the waiting one
    /// (the person answers what the phone holds now) without a new prompt.
    public mutating func receive(_ request: MobileHostPairRequest, at now: Date) -> Outcome {
        if let waiting = self.request(id: request.phoneDeviceID) {
            if !waiting.sameKeys(as: request) {
                pending = pending.map { $0.phoneDeviceID == request.phoneDeviceID ? request : $0 }
            }
            return .repeated
        }
        guard !isQuiet(at: now), pending.count < Self.limit else {
            blocked += 1
            return .blocked
        }
        pending.append(request)
        return .ask
    }

    /// The person answered phone `id`'s request (in its prompt or in Settings).
    /// Don't Allow quiets prompts for ``quietPeriod``.
    @discardableResult
    public mutating func answer(id: String, allowed: Bool, at now: Date) -> MobileHostPairRequest? {
        guard let request = request(id: id) else { return nil }
        pending.removeAll { $0.phoneDeviceID == id }
        if !allowed { quietUntil = now.addingTimeInterval(Self.quietPeriod) }
        return request
    }

    /// A phone signed out or was removed: its waiting request goes.
    public mutating func forget(id: String) {
        pending.removeAll { $0.phoneDeviceID == id }
    }
}
