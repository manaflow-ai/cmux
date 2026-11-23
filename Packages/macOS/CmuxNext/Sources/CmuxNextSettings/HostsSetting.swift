import Foundation

/// `machines.hosts` in cmux-next.json: computers declared by hand (CMUX-673),
/// each a label and the ssh endpoints tried in order:
///
/// ```jsonc
/// "machines": { "hosts": [
///   { "label": "studio", "endpoints": ["studio.local", "ssh://leo@100.64.0.7:2222"], "icon": "desktopcomputer" }
/// ] }
/// ```
///
/// cmux-config `hosts.rs` owns the rule and `cmux hosts list|check` reads the list; this is the
/// Settings write check, the same rule (and webviews validate.ts `isMachineHost`).
public nonisolated struct HostsSetting: Sendable {
    public init() {}

    /// Whether `value` is a list of hosts with no label twice (ignoring case).
    public static func accepts(_ value: JSONValue) -> Bool {
        guard case .array(let items) = value else { return false }
        var labels = Set<String>()
        for item in items {
            guard let label = label(of: item) else { return false }
            guard labels.insert(label.lowercased()).inserted else { return false }
        }
        return true
    }

    /// The trimmed label of a valid host, else nil.
    private static func label(of value: JSONValue) -> String? {
        guard case .object(let members) = value, let raw = members["label"]?.stringValue else { return nil }
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, raw.count <= 64 else { return nil }
        let endpoints: [JSONValue]
        switch (members["endpoints"], members["endpoint"]) {
        case (.array(let list)?, nil):
            guard !list.isEmpty, list.count <= 16 else { return nil }
            endpoints = list
        case (nil, let one?):
            endpoints = [one]
        default:
            return nil
        }
        guard endpoints.allSatisfy({ $0.stringValue.map(isEndpoint) ?? false }) else { return nil }
        for key in ["icon", "id"] {
            if let member = members[key], member.stringValue == nil { return nil }
        }
        return label
    }

    /// An ssh destination: `ssh://[user@]host[:port]` or what ssh takes (`[user@]host`, an alias).
    static func isEndpoint(_ text: String) -> Bool {
        guard !text.isEmpty, !text.hasPrefix("-"),
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return false }
        guard let range = text.range(of: "://") else { return true }
        guard text[..<range.lowerBound].lowercased() == "ssh" else { return false }
        var authority = String(text[range.upperBound...])
        if authority.hasSuffix("/") { authority.removeLast() }
        guard !authority.contains("/") else { return false }
        var hostPort = Substring(authority)
        if let at = authority.lastIndex(of: "@") {
            guard at != authority.startIndex else { return false }
            hostPort = authority[authority.index(after: at)...]
        }
        let host: Substring
        var port: Substring?
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return false }
            host = hostPort[hostPort.index(after: hostPort.startIndex)..<close]
            let after = hostPort[hostPort.index(after: close)...]
            if after.hasPrefix(":") { port = after.dropFirst() } else if !after.isEmpty { return false }
        } else if let colon = hostPort.lastIndex(of: ":") {
            host = hostPort[..<colon]
            guard !host.contains(":") else { return false }
            port = hostPort[hostPort.index(after: colon)...]
        } else {
            host = hostPort
        }
        if let port {
            guard !port.isEmpty, port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber),
                  let number = UInt16(port), number > 0 else { return false }
        }
        return !host.isEmpty && !host.hasPrefix("-")
    }
}
