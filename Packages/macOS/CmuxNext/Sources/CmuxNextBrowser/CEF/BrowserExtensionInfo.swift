public import Foundation

/// One installed Chromium extension of a profile, as `cmux_ext_list` (fork
/// API v3) reports it. Mirrors a chrome://extensions card.
public nonisolated struct BrowserExtensionInfo: Hashable, Sendable, Identifiable {
    public enum Location: String, Sendable {
        case unpacked
        case commandLine = "command_line"
        case webstore
        case policy
        case other
    }

    public var id: String
    public var name: String
    public var version: String
    public var summary: String
    public var manifestVersion: Int
    public var location: Location
    public var isEnabled: Bool
    public var isTerminated: Bool
    public var isBlocklisted: Bool
    /// Chromium `disable_reason::DisableReason` values.
    public var disableReasons: [Int]
    public var hasAction: Bool
    public var isPinned: Bool
    /// False for policy-installed extensions: the user cannot toggle or remove them.
    public var mayModify: Bool
    public var mustRemainEnabled: Bool
    public var optionsURL: URL?
    /// The largest bundled icon up to 128 px, on disk.
    public var iconPath: String?
    public var path: String

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

    /// Removable by the user (command-line extensions come back on the next
    /// launch, so they are not offered for removal).
    public var canRemove: Bool { mayModify && location != .commandLine }
    public var canToggle: Bool { mayModify && !(isEnabled && mustRemainEnabled) && !isBlocklisted }

    /// Decodes the fork's JSON array. Invalid input yields an empty list.
    /// Sorted by name, as chrome://extensions shows them.
    public static func decodeList(_ json: String) -> [BrowserExtensionInfo] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([Wire].self, from: data) else {
            return []
        }
        return items.map { item in
            BrowserExtensionInfo(
                id: item.id, name: item.name ?? item.id, version: item.version ?? "",
                summary: item.description ?? "", manifestVersion: item.manifest_version ?? 3,
                location: Location(rawValue: item.location ?? "") ?? .other,
                isEnabled: item.enabled ?? false, isTerminated: item.terminated ?? false,
                isBlocklisted: item.blocklisted ?? false, disableReasons: item.disable_reasons ?? [],
                hasAction: item.has_action ?? false, isPinned: item.pinned ?? false,
                mayModify: item.may_modify ?? true, mustRemainEnabled: item.must_remain_enabled ?? false,
                optionsURL: item.options_url.flatMap(URL.init(string:)), iconPath: item.icon_path,
                path: item.path ?? ""
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The list an older fork (no management API) can offer: the enabled
    /// extensions that have a toolbar action.
    public static func fromActions(_ actions: [CEFExtensionAction]) -> [BrowserExtensionInfo] {
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
        var manifest_version: Int?
        var location: String?
        var enabled: Bool?
        var terminated: Bool?
        var blocklisted: Bool?
        var disable_reasons: [Int]?
        var has_action: Bool?
        var pinned: Bool?
        var may_modify: Bool?
        var must_remain_enabled: Bool?
        var options_url: String?
        var icon_path: String?
        var path: String?
    }
}

/// Chrome's extension pages.
public enum BrowserExtensionLinks {
    public static let webStore = URL(string: "https://chromewebstore.google.com/category/extensions")!
    public static let manage = URL(string: "chrome://extensions")!
}
