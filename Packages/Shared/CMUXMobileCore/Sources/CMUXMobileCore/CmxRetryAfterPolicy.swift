public import Foundation
internal import class CmuxSafeConcurrency.OnceContinuation
internal import func CmuxSafeConcurrency.withOnceThrowingContinuation
#if canImport(FoundationNetworking)
public import FoundationNetworking
#endif

/// Shared interpretation of HTTP `Retry-After` for every automatic client
/// retry owner. A server directive is a minimum wait, never a replacement for
/// a longer local backoff.
public struct CmxRetryAfterPolicy: Sendable {
    public init() {}

    public let defaultRateLimitSeconds = 60

    /// Parses either delta-seconds or an HTTP-date. Invalid, zero, and expired
    /// directives return nil so callers can apply their documented fallback.
    public func seconds(
        from value: String?,
        now: Date = Date()
    ) -> Int? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let seconds = Int(raw), seconds > 0 {
            return seconds
        }
        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'",
            "EEEE',' dd-MMM-yy HH':'mm':'ss 'GMT'",
            "EEE MMM d HH':'mm':'ss yyyy",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let deadline = formatter.date(from: raw) {
                let remaining = roundedUpSeconds(deadline.timeIntervalSince(now))
                return remaining > 0 ? remaining : nil
            }
        }
        return nil
    }

    public func seconds(
        from response: HTTPURLResponse,
        now: Date = Date(),
        defaultSeconds: Int? = nil
    ) -> Int? {
        seconds(
            from: response.value(forHTTPHeaderField: "Retry-After"),
            now: now
        ) ?? defaultSeconds.flatMap { $0 > 0 ? $0 : nil }
    }

    public func delay(
        localSeconds: TimeInterval,
        retryAfterSeconds: Int?
    ) -> TimeInterval {
        max(localSeconds, TimeInterval(max(0, retryAfterSeconds ?? 0)))
    }

    /// Floating point rounds Int.max up to 2^63. Saturate that conversion
    /// without shortening ordinary server directives or trapping on restore.
    public func roundedUpSeconds(_ seconds: TimeInterval) -> Int {
        guard seconds > 0 else { return 0 }
        return seconds.rounded(.up).saturatedInteger(Int.self) ?? 0
    }

    /// Sleep in representable chunks while preserving the entire requested
    /// wait. Converting an arbitrary server delay to UInt64 nanoseconds traps.
    public func sleep(
        seconds: TimeInterval,
        using sleeper: @Sendable (TimeInterval) async throws -> Void = {
            try await CmxRetryAfterPolicy.toleratedSleep(seconds: $0, on: ContinuousClock())
        }
    ) async throws {
        var remaining = seconds
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = min(remaining, 86_400)
            try await sleeper(chunk)
            remaining -= chunk
        }
    }

    /// One Retry-After wait on `clock` that may fire up to min(10%, 1 s)
    /// late, so the kernel can coalesce it with other wakes; it never fires
    /// early. `@usableFromInline` because the public `sleep(seconds:using:)`
    /// calls it from its default argument.
    @usableFromInline
    static func toleratedSleep(seconds: TimeInterval, on clock: any Clock<Duration>) async throws {
        let wait = Duration.seconds(seconds)
        // wakeup-allow: backoff the server's Retry-After cooldown, one wait per directive.
        try await clock.sleep(for: wait, tolerance: wait.flexibleWakeTolerance)
    }
}

/// Transport-neutral rate-limit error used when Foundation exposes an HTTP
/// handshake response only after a WebSocket operation fails.
public struct CmxRateLimitedError: CmxRetryAfterProviding, Equatable {
    public let retryAfterSeconds: Int?

    public init(retryAfterSeconds: Int?) {
        self.retryAfterSeconds = retryAfterSeconds
    }
}

/// One monotonic cooldown shared by all triggers that can reach the same
/// endpoint. Concurrent callers join the deadline, and a later directive may
/// extend but never shorten it.
public actor CmxRetryAfterGate {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let now: @Sendable () -> TimeInterval
    private let sleep: Sleep
    private var deadline: TimeInterval?
    private var sending = false
    private var sendWaiters: [(UUID, OnceContinuation<Void, any Error>)] = []

    public init() {
        now = { ProcessInfo.processInfo.systemUptime }
        sleep = { try await CmxRetryAfterPolicy.toleratedSleep(seconds: $0, on: ContinuousClock()) }
    }

    /// The production sleep on an injected clock, for tests that read the
    /// tolerance each cooldown wait asks for.
    init(
        now: @escaping @Sendable () -> TimeInterval,
        clock: any Clock<Duration>
    ) {
        self.now = now
        sleep = { try await CmxRetryAfterPolicy.toleratedSleep(seconds: $0, on: clock) }
    }

    init(
        now: @escaping @Sendable () -> TimeInterval,
        sleep: @escaping Sleep
    ) {
        self.now = now
        self.sleep = sleep
    }

    public func extend(by seconds: Int) {
        guard seconds > 0 else { return }
        let candidate = now() + TimeInterval(seconds)
        deadline = max(deadline ?? candidate, candidate)
    }

    public func remainingSeconds() -> Int? {
        guard let deadline else { return nil }
        let remaining = CmxRetryAfterPolicy().roundedUpSeconds(deadline - now())
        if remaining <= 0 {
            self.deadline = nil
            return nil
        }
        return remaining
    }

    public func wait() async throws {
        while let deadline {
            let remaining = deadline - now()
            guard remaining > 0 else {
                self.deadline = nil
                return
            }
            try Task.checkCancellation()
            // wakeup-allow: deadline it wakes once at the cooldown's end; it loops only when a later 429 extended it.
            try await sleep(min(remaining, 86_400))
        }
    }

    /// Serialize final network admission through response handling. A 429 is
    /// recorded before the next queued request can pass its cooldown check.
    public func perform<Value: Sendable>(
        waitForCooldown: Bool = true,
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if sending {
                try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
                    sendWaiters.append((id, continuation))
                }
            } else {
                sending = true
            }
        } onCancel: {
            Task { await self.cancelSendWaiter(id) }
        }
        defer { releaseSend() }
        try Task.checkCancellation()
        if !waitForCooldown, let seconds = remainingSeconds() {
            throw CmxRateLimitedError(retryAfterSeconds: seconds)
        }
        try await wait()
        try Task.checkCancellation()
        return try await operation()
    }

    private func cancelSendWaiter(_ id: UUID) {
        guard let index = sendWaiters.firstIndex(where: { $0.0 == id }) else { return }
        sendWaiters.remove(at: index).1.resume(throwing: CancellationError())
    }

    private func releaseSend() {
        if sendWaiters.isEmpty {
            sending = false
        } else {
            sendWaiters.removeFirst().1.resume(returning: ())
        }
    }
}
