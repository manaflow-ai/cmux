/// One cmux-tui session the app federates (plans/cmux-next/data-model.md
/// 1.1): the home session (the local daemon) or a remote one (SSH, Cloud).
public struct ControlSessionInfo: Sendable, Hashable {
    /// Stable key: the session's `registry_id` (lowercase UUID), or
    /// `machine:<machineID>` for a daemon that has not reported one yet.
    public var id: String
    /// The unique name that qualifies this session's object ids
    /// (`build-box` in `build-box:workspace:3`; data-model.md 1.3). The home
    /// session's ids omit it.
    public var qualifier: String
    /// The App's machine id (`local`, a Cloud machine id, an SSH machine id).
    public var machineID: String
    /// The host name the daemon reports (`identify.machine_name`), else the
    /// App's name for the machine.
    public var machineName: String?
    /// The daemon's session name (`identify.session`).
    public var sessionName: String?
    public var isHome: Bool
    /// `connecting`, `connected`, `disconnected`, or `failed`.
    public var state: String
    /// `local`, `ssh`, or `cloud`.
    public var transport: String

    public init(id: String, qualifier: String, machineID: String, machineName: String? = nil, sessionName: String? = nil,
                isHome: Bool = false, state: String = "connected", transport: String = "local") {
        self.id = id
        self.qualifier = qualifier
        self.machineID = machineID
        self.machineName = machineName
        self.sessionName = sessionName
        self.isHome = isHome
        self.state = state
        self.transport = transport
    }
}

/// Unique session qualifiers (data-model.md 1.3): a session's name when no
/// other session shares it, else its name plus a `registry_id` prefix.
public struct ControlSessionNaming: Sendable {
    public static let shared = Self()
    public struct Candidate: Sendable, Hashable {
        public var id: String
        public var name: String?

        public init(id: String, name: String?) {
            self.id = id
            self.name = name
        }
    }

    /// Qualifier per candidate id. Names become one token: lowercase ASCII
    /// letters, digits, `.`, `_` and `-`, every other run replaced by `-`, so
    /// a qualifier never contains the `:` that separates it from the ref.
    public func qualifiers(_ candidates: [Candidate]) -> [String: String] {
        let bases = candidates.map { candidate in (candidate.id, token(candidate.name) ?? idPrefix(candidate.id)) }
        var counts: [String: Int] = [:]
        for (_, base) in bases { counts[base, default: 0] += 1 }
        var result: [String: String] = [:]
        for (id, base) in bases {
            result[id] = counts[base, default: 0] > 1 || reserved.contains(base) ? "\(base)-\(idPrefix(id))" : base
        }
        return result
    }

    /// Names a qualifier may never take: they already mean something in a ref.
    let reserved: Set<String> = ["window", "workspace", "pane", "surface", "tab", "home", "local", "handle", "terminal"]

    func token(_ name: String?) -> String? {
        guard let name else { return nil }
        var out = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            let keep = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "." || scalar == "_" || scalar == "-"
            if keep {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        out = String(out.prefix(48))
        while out.hasSuffix("-") || out.hasSuffix(".") { out.removeLast() }
        return out.isEmpty || Int(out) != nil ? nil : out
    }

    /// The first 8 hex digits of a session id (`machine:` ids hash to hex).
    func idPrefix(_ id: String) -> String {
        let hex = id.lowercased().filter(\.isHexDigit)
        if id.hasPrefix("machine:") || hex.count < 8 {
            var hash: UInt32 = 2_166_136_261
            for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
            let hex = String(hash, radix: 16)
            return String(repeating: "0", count: 8 - hex.count) + hex
        }
        return String(hex.prefix(8))
    }
}
