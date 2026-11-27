/// The release ring a cmux NEXT build follows inside its one appcast (`updates.channel`).
///
/// Rings are a ladder of `sparkle:channel` tags: each ring accepts its own tag and every
/// slower ring's, so a faster ring always gets at least what a slower one gets. CI tags an
/// item `cmux-next-canary` while the team ring runs it, retags it `cmux-next` when it is
/// promoted to everyone, and `cmux-next-stable` once it has soaked. Sparkle never offers a
/// lower build, so moving to a slower ring waits for that ring to catch up; it does not downgrade.
public enum UpdateRing: String, CaseIterable, Sendable {
    /// Soaked nightlies only.
    case stable
    /// Every nightly after its canary verdict; what every cmux NEXT build followed before rings.
    case nightly
    /// New builds as soon as they are signed, before promotion (the team ring).
    case canary
    /// Signed builds cut between nightlies as well.
    case dev

    /// The `sparkle:channel` tag of items published to this ring.
    public var sparkleChannel: String {
        switch self {
        case .stable: "cmux-next-stable"
        case .nightly: UpdateFeedResolver.Channel.nightlyNextSparkleChannel
        case .canary: "cmux-next-canary"
        case .dev: "cmux-next-dev"
        }
    }

    /// The tags this ring accepts: its own and every slower ring's.
    public var acceptedSparkleChannels: Set<String> {
        Set(Self.allCases.prefix { $0 != self }.map(\.sparkleChannel) + [sparkleChannel])
    }
}
