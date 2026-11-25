/// The pending "Connecting to <host>…" row of an SSH machine with no workspace row yet, from
/// Connect until its first workspace lists or the link stops connecting (cx-gaq9): its row id, and
/// the one window it lists in (#31490). A row lists in the window that asked for the connect while
/// it is open, else in the oldest open normal window, so a window opened later starts clean (#26632).
public struct ConnectingRowWindows: Equatable, Sendable {
    /// The row id prefix; the rest is the machine id.
    public static let prefix = "ssh-connecting:"

    /// Open window ids, oldest first, with normal windows before incognito ones, then a window
    /// still being made (the launch window before its controller is listed).
    public let open: [String]

    public init(open: [String], incognito: (String) -> Bool, making window: String?) {
        let open = open.filter { !incognito($0) } + open.filter(incognito)
        self.open = window.map { open.contains($0) ? open : open + [$0] } ?? open
    }

    /// The window a connecting row lists in: `requester` while it is open, else the oldest.
    public func owner(requestedBy requester: String?) -> String? {
        if let requester, open.contains(requester) { return requester }
        return open.first
    }

    /// The machine id of a connecting row id, or nil for another row.
    public static func machine(of id: String) -> String? {
        id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil
    }
}
