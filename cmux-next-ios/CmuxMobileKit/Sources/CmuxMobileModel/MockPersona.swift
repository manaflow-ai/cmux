// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import Foundation

/// Who the mock account is. The default names a teammate, whose sample
/// data the tests and recordings know; `CMUX_MOBILE_MOCK_PERSONA=store`
/// (App Store screenshots, `scripts/ci/cmux-next-ios-sim.sh` shots) swaps
/// in a fictional person and team, so public screenshots carry no real
/// person's or company's name.
public struct MockPersona: Equatable, Sendable {
    public var userName: String
    public var userEmail: String
    /// The first name Macs are called after ("<owner>'s Mac Studio").
    public var owner: String
    /// The mock's shared team.
    public var teamName: String

    public static let standard = MockPersona(
        userName: "Aziz Albahar", userEmail: "aziz@example.com", owner: "Aziz", teamName: "Manaflow"
    )
    public static let store = MockPersona(
        userName: "Sam Rivera", userEmail: "sam@example.com", owner: "Sam", teamName: "Studio"
    )

    public static var current: MockPersona {
        current(environment: ProcessInfo.processInfo.environment)
    }

    static func current(environment: [String: String]) -> MockPersona {
        environment["CMUX_MOBILE_MOCK_PERSONA"] == "store" ? .store : .standard
    }

    /// "<owner>'s <device>".
    public func mac(_ device: String) -> String { "\(owner)'s \(device)" }
}
#endif
