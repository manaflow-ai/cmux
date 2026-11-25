/// `developerTools.overloadNotice` in cmux-next.json: whether an agent chat warns that this Mac is
/// overloaded ("This Mac is overloaded: load 75 on 15 cores. Builds and agents will be slow." above
/// the composer, webviews OverloadNotice.tsx). Off by default
/// (https://github.com/manaflow-ai/cmux/issues/56156): the pane then never asks acpmux for the
/// verdict at all. It rides the agent pane's `composer` event as `showOverloadNotice`.
///
/// Read from the snapshot's document, not stored: only a literal `true` turns it on.
public nonisolated struct HostOverloadNoticeSetting: Sendable {
    // `configPath` and `fallback` (off) are generated from schemas/settings/source/developer-tools.json.

    /// Makes the value from its parts.
    public init() {}

    /// The value in `root`: on only for a literal `true`.
    public func value(in root: JSONValue) -> Bool {
        root.value(at: Self.configPath)?.boolValue ?? Self.fallback
    }
}
