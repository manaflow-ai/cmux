public import Foundation

/// The `remote_view` tab record (plans/cmux-next/remote-desktop.md 7 and
/// 10.1): which desktop a tab shows, never the stream. The workspace store
/// owns it as a browser tab record whose URL is
/// `cmux://remote-view?host=<host>&target=<target>&mode=<mode>`, like the
/// other app pages (`cmux://history`, `cmux://agent-activity`), so it is
/// persisted, moved, closed and restored by the store with no daemon change.
/// A record from a remote machine's tree never opens here: the App opens
/// only web pages from remote records (`RemoteRelayPolicy`).
///
/// Every field is validated on parse; a record that does not parse is not
/// a remote view tab, and the App shows it as an unknown page.
public nonisolated struct RemoteViewTabRecord: Sendable, Hashable {
    /// The scheme and host of the record URL.
    public static let scheme = "cmux"
    public static let urlHost = "remote-view"
    /// Longest machine name or id the record keeps.
    public static let maximumHostLength = 128

    /// What part of the host the tab shows.
    public enum Target: Sendable, Hashable {
        /// One display, by the host's display number.
        case display(UInt32)
        /// One window of the host's console user, by the host's window id.
        case window(UInt64)
        /// A virtual display sized to the pane (server Macs, Linux, VMs).
        case virtual

        /// `display:<n>`, `window:<id>` or `virtual`.
        public var rawValue: String {
            switch self {
            case let .display(id): "display:\(id)"
            case let .window(id): "window:\(id)"
            case .virtual: "virtual"
            }
        }

        public init?(rawValue: String) {
            if rawValue == "virtual" {
                self = .virtual
                return
            }
            let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, Self.isDigits(parts[1]) else { return nil }
            switch parts[0] {
            case "display":
                guard let id = UInt32(parts[1]) else { return nil }
                self = .display(id)
            case "window":
                guard let id = UInt64(parts[1]) else { return nil }
                self = .window(id)
            default:
                return nil
            }
        }

        /// ASCII digits only (no sign, no spaces), 1 to 20 of them.
        private static func isDigits(_ text: Substring) -> Bool {
            !text.isEmpty && text.count <= 20 && text.utf8.allSatisfy { (0x30...0x39).contains($0) }
        }
    }

    /// The machine: its directory id or name (`local` for this Mac).
    public var host: String
    public var target: Target
    /// The mode the tab asks for when it connects. Control still needs the
    /// host's authorization and only sends input while the pane is focused.
    public var mode: RemoteControlMode

    /// Nil when `host` is not a valid machine name.
    public init?(host: String, target: Target = .display(1), mode: RemoteControlMode = .view) {
        guard Self.isValidHost(host) else { return nil }
        self.host = host
        self.target = target
        self.mode = mode
    }

    /// Parses a record URL; nil for any other URL, an invalid field, or a
    /// user, password, port, path or fragment part.
    /// Unknown query items are ignored (newer builds may add fields);
    /// a repeated known item is invalid.
    public init?(url: URL?) {
        guard Self.matches(url), let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil else { return nil }
        var fields: [String: String] = [:]
        for item in components.queryItems ?? [] where ["host", "target", "mode"].contains(item.name) {
            guard fields[item.name] == nil, let value = item.value else { return nil }
            fields[item.name] = value
        }
        guard let host = fields["host"] else { return nil }
        let target: Target
        if let raw = fields["target"] {
            guard let parsed = Target(rawValue: raw) else { return nil }
            target = parsed
        } else {
            target = .display(1)
        }
        let mode: RemoteControlMode
        if let raw = fields["mode"] {
            guard let parsed = RemoteControlMode(rawValue: raw) else { return nil }
            mode = parsed
        } else {
            mode = .view
        }
        self.init(host: host, target: target, mode: mode)
    }

    /// The record URL, fields in a fixed order.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.urlHost
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "target", value: target.rawValue),
            URLQueryItem(name: "mode", value: mode.rawValue),
        ]
        // A scheme, a host, no path and query items always form a URL; /dev/null stands in otherwise.
        return components.url ?? URL(fileURLWithPath: "/dev/null")
    }

    /// True for `cmux://remote-view` with any query (valid or not): the App
    /// shows such a tab as a remote view page, or as invalid.
    public static func matches(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == scheme else { return false }
        return url.host()?.lowercased() == urlHost
    }

    /// 1 to 128 of `A-Z a-z 0-9 . _ -`, starting with a letter or digit
    /// (no `:`, so no port can ride in the name).
    public static func isValidHost(_ host: String) -> Bool {
        let bytes = Array(host.utf8)
        guard let first = bytes.first, bytes.count <= maximumHostLength, isAlphanumeric(first) else { return false }
        return bytes.allSatisfy { isAlphanumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}

public nonisolated extension RemoteViewTabRecord {
    /// The tab title: the host's name, or "Remote Desktop" for an address
    /// that did not parse.
    static func tabTitle(_ record: RemoteViewTabRecord?) -> String {
        record?.host ?? RemoteViewStrings.genericTabTitle
    }
}
