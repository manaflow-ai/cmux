public import Foundation

/// The Public Suffix List (`Resources/PublicSuffixList.dat`). Stub: the red
/// commit of its tests.
public nonisolated struct PublicSuffixList: Sendable {
    public init(listText: String) {}
    public static func bundled() -> PublicSuffixList? { PublicSuffixList(listText: "") }
    public var ruleCount: Int { 0 }
    public func registrableDomain(of host: String) -> String? { host.lowercased() }
}
