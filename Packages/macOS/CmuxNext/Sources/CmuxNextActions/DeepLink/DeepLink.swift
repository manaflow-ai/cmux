public import Foundation

/// A link to one object in cmux, such as `cmux://tab/tab_<hex>`.
///
/// The scheme is the running build's URL scheme, the one the sign-in
/// callback uses (`CloudConfiguration.callbackScheme`: `cmux` in Release,
/// `cmux-dev` in Debug, `cmux-dev-<tag>` in tagged builds). The host names
/// the kind and the one path segment is an opaque cmux-tui resource id
/// (`ws_`, `pane_`, `tab_` plus 32 lowercase hex digits), never a numeric
/// handle. `?machine=machine_<hex>` may name the machine the target lives on;
/// every other query parameter is ignored, so a link can never carry a
/// command. The `auth-callback` host is the sign-in callback, never a link.
///
/// Nightly's `cmux://workspace/<uuid>[/pane/<uuid>|/surface/<uuid>|/panel/<uuid>]`
/// forms, with their `stable_workspace_id` and `stable_surface_id`
/// fallbacks, parse to the `legacy` targets.
///
/// ```swift
/// let link = DeepLink(.tab("tab_0123456789abcdef0123456789abcdef"))
/// let url = link.url(scheme: "cmux")        // cmux://tab/tab_0123…
/// DeepLink.parse(url!, scheme: "cmux") == link  // true
/// ```
public nonisolated struct DeepLink: Sendable, Hashable {
    /// What a link opens.
    public nonisolated enum Target: Sendable, Hashable {
        /// A workspace by its `ws_` resource id.
        case workspace(String)
        /// A pane by its `pane_` resource id; it opens on the pane's selected tab.
        case pane(String)
        /// A terminal, browser or agent tab by its `tab_` resource id.
        case tab(String)
        /// An acpmux agent chat session, and optionally one turn in it
        /// (`#turn-<turnId>`).
        case session(String, turn: String?)
        /// Nightly's `workspace/<uuid>`: the durable workspace key, with the
        /// `stable_workspace_id` fallback.
        case legacyWorkspace(UUID, fallback: UUID?)
        /// Nightly's `workspace/<uuid>/pane/<uuid>`.
        case legacyPane(workspace: UUID, pane: UUID)
        /// Nightly's `workspace/<uuid>/surface/<uuid>` (or `/panel/`), with the
        /// `stable_workspace_id` and `stable_surface_id` fallbacks.
        case legacySurface(workspace: UUID, surface: UUID, fallbackWorkspace: UUID?, fallbackSurface: UUID?)
    }

    /// The object the link opens.
    public var target: Target
    /// The `machine_` resource id of the machine the target lives on, when
    /// the link names one. Ids are globally unique, so it is a hint for the
    /// refusal, never needed to find the target.
    public var machine: String?

    /// A link to `target`.
    ///
    /// - Parameters:
    ///   - target: The object the link opens.
    ///   - machine: The `machine_` id of a remote machine; nil for none.
    public init(_ target: Target, machine: String? = nil) {
        self.target = target
        self.machine = machine
    }

    /// The host of the sign-in callback (`<scheme>://auth-callback`), which
    /// is never a link.
    public static let authCallbackHost = "auth-callback"

    /// The link as a URL in `scheme`, the running build's scheme.
    ///
    /// - Parameter scheme: The URL scheme (`cmux`, `cmux-dev`, `cmux-dev-<tag>`).
    /// - Returns: The URL, or nil when an id does not fit its kind's grammar,
    ///   so a formatted link always parses back to the same value.
    public func url(scheme: String) -> URL? {
        nil
    }

    /// The fragment that names a turn: `#turn-<turnId>`.
    static let turnFragmentPrefix = "turn-"

    /// Whether every id fits its kind's grammar (``parse(_:scheme:)``).
    var isWellFormed: Bool {
        if let machine, !Self.isResourceID(machine, prefix: "machine_") { return false }
        switch target {
        case .workspace(let id): return Self.isResourceID(id, prefix: "ws_")
        case .pane(let id): return Self.isResourceID(id, prefix: "pane_")
        case .tab(let id): return Self.isResourceID(id, prefix: "tab_")
        case .session(let id, let turn): return Self.isToken(id) && (turn.map(Self.isToken) ?? true)
        case .legacyWorkspace, .legacyPane, .legacySurface: return true
        }
    }

    /// `<prefix>` plus 128 bits as 32 lowercase hex digits
    /// (cmux-tui/spec/resource-api-v2.md).
    static func isResourceID(_ text: String, prefix: String) -> Bool {
        guard text.hasPrefix(prefix) else { return false }
        let hex = text.utf8.dropFirst(prefix.utf8.count)
        return hex.count == 32 && hex.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// An acpmux session or turn id: 1 to 200 ASCII letters, digits, `-`,
    /// `_` or `.`. Nothing that needs escaping in a URL.
    static func isToken(_ text: String) -> Bool {
        (1...200).contains(text.utf8.count) && text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
        }
    }

    /// An RFC 3986 scheme: a letter, then letters, digits, `+`, `-` or `.`.
    static func isScheme(_ text: String) -> Bool {
        guard let first = text.utf8.first, (65...90).contains(first) || (97...122).contains(first) else { return false }
        return text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
        }
    }
}
