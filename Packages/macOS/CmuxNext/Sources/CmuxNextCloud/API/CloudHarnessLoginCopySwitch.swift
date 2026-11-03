public import Foundation
import CmuxNextCompat

/// The remote off switch for a Release build's copy of the person's Claude login to their own Cloud
/// machine (Leo, 2026-11-02: "A remote off switch, so if Anthropic objects we turn it off for
/// everyone within minutes and fall back to the one-click sign-in"). The API Worker answers it
/// (`GET /v1/cloud/harness-login-copy`, cmux-platform) and the app asks it before each Release copy,
/// so turning it off there stops the next new machine's copy with no app update; that machine's chat
/// then offers the one-click "Sign in to Claude" (acpmux `agent_login`).
///
/// Fail closed: an answer older than its `ttlSeconds`, a failed read, or no read at all is off. DEV
/// and NIGHTLY builds do not read it (their copy is the dogfood gate's).
public final class CloudHarnessLoginCopySwitch: Sendable {
    /// One answer and when it came.
    struct Answer: Sendable, Equatable {
        var enabled: Bool
        var ttl: Duration
        var at: ContinuousClock.Instant
    }

    private let state = Mutex<Answer?>(nil)
    private let clock = ContinuousClock()

    public init() {}

    /// The last answer while it is fresh; nil (off) when never read, failed, or past its ttl.
    public var current: Bool? {
        let now = clock.now
        return state.withLock { answer in
            guard let answer, now - answer.at <= answer.ttl else { return nil }
            return answer.enabled
        }
    }

    /// Reads the switch once and keeps the answer; a failed read forgets the last one (off).
    /// Answers ``current``.
    @discardableResult
    public func read(_ owner: CloudOwnerAPIClient) async -> Bool? {
        let answer = try? await owner.harnessLoginCopy()
        let now = clock.now
        state.withLock { $0 = answer.map { Answer(enabled: $0.enabled, ttl: .seconds($0.ttlSeconds), at: now) } }
        return current
    }

    /// Test seam: keeps `enabled` as if read `age` ago.
    func set(_ enabled: Bool?, ttlSeconds: Int = 300, age: Duration = .zero) {
        let at = clock.now - age
        state.withLock { $0 = enabled.map { Answer(enabled: $0, ttl: .seconds(ttlSeconds), at: at) } }
    }
}

extension CloudOwnerAPIClient {
    /// The switch's answer: `{enabled, ttlSeconds}` (or that object under `value`).
    public struct HarnessLoginCopy: Decodable, Sendable, Equatable {
        public var enabled: Bool
        public var ttlSeconds: Int
    }

    /// The longest an answer is trusted, whatever the route says: the switch takes effect within this.
    public static let harnessLoginCopyMaxTTL = 300

    /// `GET /v1/cloud/harness-login-copy`: whether a Release build may copy the person's Claude login
    /// to their own machine now. Bounded to 5 seconds; any failure throws (the caller reads it as off).
    public func harnessLoginCopy() async throws -> HarnessLoginCopy {
        let data = try await get("/v1/cloud/harness-login-copy", query: [], timeout: .seconds(5))
        return try Self.decodeHarnessLoginCopy(data)
    }

    static func decodeHarnessLoginCopy(_ data: Data) throws -> HarnessLoginCopy {
        struct Wrapped: Decodable { var value: HarnessLoginCopy }
        let decoder = JSONDecoder()
        var answer: HarnessLoginCopy
        if let plain = try? decoder.decode(HarnessLoginCopy.self, from: data) { answer = plain } else {
            do { answer = try decoder.decode(Wrapped.self, from: data).value } catch {
                throw CloudAPIError.decoding("/v1/cloud/harness-login-copy: \(error)")
            }
        }
        answer.ttlSeconds = max(0, min(answer.ttlSeconds, harnessLoginCopyMaxTTL))
        return answer
    }
}
