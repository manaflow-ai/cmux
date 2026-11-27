public import Foundation

/// What the invite flow asks of the app (the cmux account and the API Worker), so it runs the same
/// in tests and the gallery with fakes. Preview and approve are not here: they are the Add Server
/// path's own intents (``ServerIntentKind/lookupCode(_:)``, ``ServerIntentKind/approveCode(code:team:name:placeChief:)``).
public nonisolated struct PairInviteService: Sendable {
    /// `server.pair.invite` (origin user): a new invite. Minting one voids the user's previous one.
    public var mint: @Sendable () async -> Result<PairInvite, PairInviteFailure>
    /// The invite's watch socket as frames, in order. The stream ends when the socket closes (its
    /// last frame says why: ``PairInviteFrame/expired`` or ``PairInviteFrame/lost``) and closes the
    /// socket when its consumer is cancelled.
    public var watch: @Sendable (PairInvite) -> AsyncStream<PairInviteFrame>

    public init(mint: @escaping @Sendable () async -> Result<PairInvite, PairInviteFailure>,
                watch: @escaping @Sendable (PairInvite) -> AsyncStream<PairInviteFrame>) {
        self.mint = mint
        self.watch = watch
    }
}

extension PairInviteService {
    /// The gallery's and demos' invite: a fixed code that expires ten minutes after `now` (the
    /// gallery passes ``MockServerScenario/referenceDate`` and the same clock to the model), and a
    /// socket that says `frames` and then stays open (the mock's arrived code is
    /// ``MockServerScenario/offerCode``, which ``MockServerSource`` previews).
    public static func mock(now: Date = Date(),
                            frames: [PairInviteFrame] = [.pending(expiresAt: nil)]) -> PairInviteService {
        let invite = PairInvite(code: mockCode, expiresAt: now.addingTimeInterval(600), watchSecret: "mock-watch-secret")
        return PairInviteService(
            mint: { .success(invite) },
            watch: { _ in
                AsyncStream(bufferingPolicy: .bufferingNewest(max(frames.count, 1))) { continuation in
                    for frame in frames { continuation.yield(frame) }
                }
            })
    }

    /// The mock invite's code.
    public static let mockCode = "7KQ4MX2D9P"
}
