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

    /// The icons of a raw `_acpmux/harnesses` reply, or nil when it is not a JSON object. Image icons
    /// carry their bytes inline (base64), so the reply can be megabytes: callers run this on a
    /// background lane, never on the main actor (hang-watch 8a1dbcadaa, cmuxterm-hq#11534).
    /// - Parameter data: The reply's JSON bytes.
    public init?(harnessesReplyData data: Data) {
        guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.init(harnessesReply: reply)
    }
}
