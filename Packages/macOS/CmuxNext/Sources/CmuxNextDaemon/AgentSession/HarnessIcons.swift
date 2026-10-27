public import Foundation

/// Every harness's icon (``HarnessIconSpec``), by harness id: what one `_acpmux/harnesses` reply
/// says. A value, so the tab strip and sidebar mappings take it as a parameter and stay pure.
public nonisolated struct HarnessIcons: Equatable, Sendable {
    /// No icons yet (no reply read): every surface keeps its brand mark or kind icon.
    public static let none = HarnessIcons(specs: [:])

    /// The icon of each harness id.
    public var specs: [String: HarnessIconSpec]

    /// - Parameter specs: The icon of each harness id.
    public init(specs: [String: HarnessIconSpec]) {
        self.specs = specs
    }

    /// The icons of a `_acpmux/harnesses` reply (its `harnesses` object); malformed entries are left out.
    /// - Parameter reply: The decoded reply.
    public init(harnessesReply reply: [String: Any]) {
        let harnesses = reply["harnesses"] as? [String: Any] ?? [:]
        self.init(specs: harnesses.compactMapValues { HarnessIconSpec(json: ($0 as? [String: Any])?["iconSpec"]) })
    }
}
