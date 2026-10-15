public import Foundation

/// One installed Chromium extension of a browser profile.
///
/// Mirrors a `chrome://extensions` card as the cmux CEF fork's `cmux_ext_list`
/// (fork API v3) reports it. The Chromium engine owns the state; cmux only
/// reads it and asks Chromium to change it. WebKit panels have no extensions.
public struct BrowserExtensionInfo: Hashable, Sendable, Identifiable {
    /// Where Chromium says the extension came from.
    public enum Location: String, Sendable {
        /// Loaded from a folder ("Load unpacked").
        case unpacked
        /// Loaded with `--load-extension` at engine start (cmux built-ins).
        case commandLine = "command_line"
        /// Installed from the Chrome Web Store.
        case webstore
        /// Forced by enterprise policy.
        case policy
        /// Any other Chromium location.
        case other
    }

    /// The 32-character Chromium extension id.
    public var id: String
    /// The manifest name.
    public var name: String
    /// The manifest version string.
    public var version: String
    /// The manifest description.
    public var summary: String
    /// The manifest's `manifest_version` (2 or 3).
    public var manifestVersion: Int
    /// Where the extension came from.
    public var location: Location
    /// True while the extension runs.
    public var isEnabled: Bool
    /// True after the extension process crashed or was killed; it stays off until reloaded.
    public var isTerminated: Bool
    /// True when Chromium's blocklist disabled it.
    public var isBlocklisted: Bool
    /// Chromium `disable_reason::DisableReason` values.
    public var disableReasons: [Int]
    /// True when the extension declares a toolbar action.
    public var hasAction: Bool
    /// True when its toolbar action is pinned next to the address bar.
    public var isPinned: Bool
    /// False for policy-installed extensions: the person cannot toggle or remove them.
    public var mayModify: Bool
    /// True when policy forbids disabling it.
    public var mustRemainEnabled: Bool
    /// The extension's options page, when it declares one.
    public var optionsURL: URL?
    /// The largest bundled icon up to 128 px, on disk.
    public var iconPath: String?
    /// The extension's folder on disk.
    public var path: String

    /// Creates an extension snapshot.
    ///
    /// Defaults describe an enabled, unpinned, user-modifiable MV3 extension
    /// with no action, which is what a test or mock usually needs.
    public init(
        id: String, name: String, version: String = "", summary: String = "", manifestVersion: Int = 3,
        location: Location = .other, isEnabled: Bool = true, isTerminated: Bool = false,
        isBlocklisted: Bool = false, disableReasons: [Int] = [], hasAction: Bool = false,
        isPinned: Bool = false, mayModify: Bool = true, mustRemainEnabled: Bool = false,
        optionsURL: URL? = nil, iconPath: String? = nil, path: String = ""
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.manifestVersion = manifestVersion
        self.location = location
        self.isEnabled = isEnabled
        self.isTerminated = isTerminated
        self.isBlocklisted = isBlocklisted
        self.disableReasons = disableReasons
        self.hasAction = hasAction
        self.isPinned = isPinned
        self.mayModify = mayModify
        self.mustRemainEnabled = mustRemainEnabled
        self.optionsURL = optionsURL
        self.iconPath = iconPath
        self.path = path
    }

    /// True when the person may remove it.
    ///
    /// Command-line extensions (cmux built-ins) come back on the next engine
    /// start, so they are not offered for removal.
    public var canRemove: Bool { mayModify && location != .commandLine }

    /// True when the person may enable or disable it.
    public var canToggle: Bool { mayModify && !(isEnabled && mustRemainEnabled) && !isBlocklisted }

    /// Decodes the fork's `cmux_ext_list` JSON array, sorted by name as
    /// `chrome://extensions` shows them.
    ///
    /// - Parameter json: The fork's JSON text.
    /// - Returns: The extensions, or an empty list for invalid input.
    public static func decodeList(_ json: String) -> [BrowserExtensionInfo] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([Wire].self, from: data) else {
            return []
        }
        return items.map { item in
            BrowserExtensionInfo(
                id: item.id, name: item.name ?? item.id, version: item.version ?? "",
                summary: item.description ?? "", manifestVersion: item.manifestVersion ?? 3,
                location: Location(rawValue: item.location ?? "") ?? .other,
                isEnabled: item.enabled ?? false, isTerminated: item.terminated ?? false,
                isBlocklisted: item.blocklisted ?? false, disableReasons: item.disableReasons ?? [],
                hasAction: item.hasAction ?? false, isPinned: item.pinned ?? false,
                mayModify: item.mayModify ?? true, mustRemainEnabled: item.mustRemainEnabled ?? false,
                optionsURL: item.optionsURL.flatMap(URL.init(string:)), iconPath: item.iconPath,
                path: item.path ?? ""
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The list an older fork without the management API can offer: the
    /// enabled extensions that have a toolbar action, none of them modifiable.
    ///
    /// - Parameter actions: The toolbar actions the fork reported.
    /// - Returns: One read-only snapshot per action.
    public static func fromActions(_ actions: [BrowserExtensionAction]) -> [BrowserExtensionInfo] {
        actions.map {
            BrowserExtensionInfo(id: $0.id, name: $0.name, isEnabled: true, hasAction: true, isPinned: $0.isPinned,
                                 mayModify: false)
        }
    }

    private struct Wire: Decodable {
        var id: String
        var name: String?
        var version: String?
        var description: String?
        var manifestVersion: Int?
        var location: String?
        var enabled: Bool?
        var terminated: Bool?
        var blocklisted: Bool?
        var disableReasons: [Int]?
        var hasAction: Bool?
        var pinned: Bool?
        var mayModify: Bool?
        var mustRemainEnabled: Bool?
        var optionsURL: String?
        var iconPath: String?
        var path: String?

        enum CodingKeys: String, CodingKey {
            case id, name, version, description, location, enabled, terminated, blocklisted, pinned, path
            case manifestVersion = "manifest_version"
            case disableReasons = "disable_reasons"
            case hasAction = "has_action"
            case mayModify = "may_modify"
            case mustRemainEnabled = "must_remain_enabled"
            case optionsURL = "options_url"
            case iconPath = "icon_path"
        }
    }
}
