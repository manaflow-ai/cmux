import Foundation

/// Whether a pushed NIGHTLY build downloads now or waits for its deltas (RFD 0166 U1; Leo
/// 2026-11-24 08:29Z, on round trips and bytes). nightly-next lists a build's `sparkle:deltas`
/// minutes after its full archive, and a download that starts before they are listed is the whole
/// ~243 MB archive where the delta from the installed build is ~13.6 MB. A release push offers the
/// build at once but holds its automatic download for up to ``window`` for the delta to be listed.
/// A person's own click never waits.
nonisolated enum DeltaWaitPolicy {
    /// The longest a pushed build's download waits for its deltas.
    static let window: Duration = .seconds(300)
    /// How often the feed is read again while waiting.
    static let recheck: Duration = .seconds(30)

    enum Decision: Equatable { case download, wait }

    /// - Parameters:
    ///   - listsDeltas: the build's feed item lists `sparkle:deltas`.
    ///   - userAsked: the person clicked to update: it takes what is available now.
    ///   - waited: how long the download has waited so far.
    static func decide(listsDeltas: Bool, userAsked: Bool, waited: Duration) -> Decision {
        if userAsked || listsDeltas || waited >= window { return .download }
        return .wait
    }
}
