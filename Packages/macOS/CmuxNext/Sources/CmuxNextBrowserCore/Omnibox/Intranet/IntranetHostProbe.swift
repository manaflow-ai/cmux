package import CmuxNextCompat
package import CmuxNextWakeups
public import Foundation

/// Checks whether a bare typed word is an intranet host (`wiki` at a company
/// whose DNS search domain resolves it), the way Chrome's intranet redirect
/// detection does, so the word loads `http://wiki/` with no setup.
///
/// Each answer waits at most `timeout`; no answer in time is "not a host"
/// (the word stays a search). With ``IntranetRedirectBehavior/withInterceptionCheck``
/// three random names are resolved first: a resolver that answers them
/// answers every name, so no bare word counts as a host. Answers are kept
/// for `answerLifetime` (a VPN that connects later is seen within it).
///
/// ```swift
/// let probe = IntranetHostProbe(lookup: SystemHostLookup(), behavior: .withInterceptionCheck)
/// if await probe.resolves("wiki") { memory.record("wiki", resolves: true) }
/// ```
public actor IntranetHostProbe {
    private let lookup: any HostLookup
    public nonisolated let behavior: IntranetRedirectBehavior
    private let timeout: Duration
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let answerLifetime: TimeInterval
    private let randomLabel: @Sendable () -> String
    private var answers: [String: (resolves: Bool, at: Date)] = [:]
    private var interception: (intercepts: Bool, at: Date)?

    /// - Parameters:
    ///   - lookup: The resolver; ``SystemHostLookup`` in the app.
    ///   - behavior: Chrome's `IntranetRedirectBehavior` policy, default 3.
    ///   - timeout: How long one lookup may take before it counts as no.
    ///   - clock: Drives the timeout; tests pass a clock they control.
    ///   - now: The time answers are stamped with.
    ///   - answerLifetime: Seconds an answer is reused.
    ///   - randomLabel: The random names of the interception check.
    public init(lookup: any HostLookup, behavior: IntranetRedirectBehavior = .withInterceptionCheck,
                timeout: Duration = .milliseconds(300), clock: any Clock<Duration> = ContinuousClock(),
                now: @escaping @Sendable () -> Date = Date.init, answerLifetime: TimeInterval = 60,
                randomLabel: @escaping @Sendable () -> String = IntranetHostProbe.makeRandomLabel) {
        self.lookup = lookup
        self.behavior = behavior
        self.timeout = timeout
        self.clock = clock
        self.now = now
        self.answerLifetime = answerLifetime
        self.randomLabel = randomLabel
    }

    /// The lowercased word when `text` is a bare single label that could be a
    /// host (letters, digits and inner hyphens, not only digits, at most 63
    /// characters); nil for anything else.
    public nonisolated static func candidate(_ text: String) -> String? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (2...63).contains(word.count), word.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }),
              !word.hasPrefix("-"), !word.hasSuffix("-"), !word.allSatisfy(\.isNumber) else { return nil }
        return word
    }

    /// Whether `label` is an intranet host under ``behavior``.
    public func resolves(_ label: String) async -> Bool {
        guard behavior != .disabled, let label = Self.candidate(label) else { return false }
        let time = now()
        if let answer = answers[label], time.timeIntervalSince(answer.at) < answerLifetime { return answer.resolves }
        if behavior == .withInterceptionCheck, await intercepts(at: time) {
            answers[label] = (false, time)
            return false
        }
        let resolves = await lookupWithDeadline(label)
        answers[label] = (resolves, time)
        return resolves
    }

    /// Whether the resolver answers names that cannot exist (checked once per lifetime).
    private func intercepts(at time: Date) async -> Bool {
        if let interception, time.timeIntervalSince(interception.at) < answerLifetime * 5 { return interception.intercepts }
        var intercepts = false
        for _ in 0..<3 where !intercepts {
            intercepts = await lookupWithDeadline(randomLabel())
        }
        interception = (intercepts, time)
        return intercepts
    }

    /// The lookup's answer, or false at the deadline, whichever comes first;
    /// a lookup that answers late is dropped (getaddrinfo ignores cancellation).
    private func lookupWithDeadline(_ host: String) async -> Bool {
        let lookup = self.lookup, timeout = self.timeout
        let deadline = DemandTimer(owner: "omnibar.intranetProbe", clock: clock)
        let answer = OneShotAnswer()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            answer.begin(continuation)
            let work = Task { answer.finish(await lookup.resolves(host)) }
            deadline.schedule(after: timeout) {
                if answer.finish(false) { work.cancel() }
            }
        }
        deadline.cancel()
        return result
    }

    /// Ten random lowercase letters, a name no real network has.
    public nonisolated static func makeRandomLabel() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return String((0..<10).map { _ in letters[Int.random(in: 0..<letters.count)] })
    }
}

/// Resumes one continuation once: with the lookup's answer or the deadline's
/// false, whichever calls ``finish(_:)`` first.
private nonisolated final class OneShotAnswer: Sendable {
    // Synchronous compare-and-set from a lookup task and a timer callback
    // racing to resume one continuation (the lock carve-out).
    private let state = Mutex<(continuation: CheckedContinuation<Bool, Never>?, answer: Bool?)>((nil, nil))

    package func begin(_ continuation: CheckedContinuation<Bool, Never>) {
        let answered = state.withLock { state -> Bool? in
            if state.answer == nil { state.continuation = continuation }
            return state.answer
        }
        if let answered { continuation.resume(returning: answered) }
    }

    /// True for the first caller, whose value resumes the waiter.
    @discardableResult
    package func finish(_ value: Bool) -> Bool {
        let (first, continuation) = state.withLock { state -> (Bool, CheckedContinuation<Bool, Never>?) in
            guard state.answer == nil else { return (false, nil) }
            state.answer = value
            defer { state.continuation = nil }
            return (true, state.continuation)
        }
        continuation?.resume(returning: value)
        return first
    }
}
