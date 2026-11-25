// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import Foundation

/// The link the mock chat and mock terminal pretend to have to the Mac
/// (`CMUX_MOBILE_MOCK_LINK`, `ComposerLinkUITests`), so typing can be measured
/// with the Mac's link healthy, slow, or down, and with frames streaming in:
///
/// - `healthy` (the default): events arrive as the mock makes them;
/// - `slow`: a congested link. What the Mac sends is held and arrives in
///   bursts every `burst` (a stalled TCP window draining at once), and what
///   the phone sends reaches the Mac `burst` later;
/// - `down`: the Mac is out of reach. The chat says it is disconnected, the
///   terminal says it is offline, and nothing the phone sends arrives.
public enum MockLinkCondition: String, Sendable {
    case healthy
    case slow
    case down

    /// How long a slow link holds what it carries.
    public static let burst: Duration = .milliseconds(600)

    public static let current = MockLinkCondition(environment: ProcessInfo.processInfo.environment)

    public init(environment: [String: String]) {
        self = environment["CMUX_MOBILE_MOCK_LINK"].flatMap(MockLinkCondition.init(rawValue:)) ?? .healthy
    }
}
#endif
