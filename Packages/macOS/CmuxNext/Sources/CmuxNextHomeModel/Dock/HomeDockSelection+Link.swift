import Foundation

extension HomeDockSelection {
    /// A message or conversation link as a selection: the page route `#/conversation/<c>[/message/<m>]`
    /// or `<scheme>://conversation/<c>[/message/<m>]` (the daemon's permalink grammar; query and
    /// fragment of a scheme link are ignored). nil for anything else.
    public init?(link: String) {
        var rest = Substring(link)
        if let scheme = rest.range(of: "://") {
            rest = rest[scheme.upperBound...].prefix { $0 != "?" && $0 != "#" }
        } else {
            while rest.first == "#" || rest.first == "/" { rest = rest.dropFirst() }
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 4, parts[0] == "conversation", Self.isLinkID(parts[1]) else { return nil }
        guard parts.count == 4 else { self.init(conversation: parts[1]); return }
        guard parts[2] == "message", Self.isLinkID(parts[3]) else { return nil }
        self.init(conversation: parts[1], message: parts[3])
    }
}
