/// The buttons the browser toolbar shows next to the address bar, in cmux.json (cx-d0d.81):
///
/// ```jsonc
/// "browser": { "toolbarButtons": ["media", "zoom", "downloads"] }
/// ```
///
/// By default the toolbar keeps only what a page needs: Back, Forward, Reload, the address bar,
/// the Extensions button (Chromium tabs), and More. Of the other buttons, the media
/// hub, the zoom level and Downloads show by default, each only while it has something to show
/// (media playing, a zoomed page, a download). Every other action (Favorites, design mode, the
/// profile, the page theme, DevTools) is in the More menu, whose Show in Toolbar items pin it
/// back; an item left out of this list is unpinned. A bad or unknown item is dropped with a
/// diagnostic. The app reads the effective root (``current(_:)``), so the snapshot type does not
/// grow.
public nonisolated struct BrowserToolbarButtonsSetting: Sendable, Hashable {
    public static let configPath = ["browser", "toolbarButtons"]
    /// Every button the list may name, in toolbar order (`BrowserToolbarButton` raw values; More
    /// always shows and is not in the list).
    public static let buttonIDs = ["media", "zoom", "favorites", "downloads", "designMode", "profile", "theme", "devTools"]
    public static let fallback = BrowserToolbarButtonsSetting(pinned: ["media", "zoom", "downloads"])

    /// The pinned buttons' ids.
    public var pinned: [String]

    public init(pinned: [String]) {
        self.pinned = pinned
    }

    /// The list in cmux.json's root; a missing list is the default.
    public static func read(_ root: JSONValue) -> BrowserToolbarButtonsSetting {
        var diagnostics: [SettingsDiagnostic] = []
        return parse(root, diagnostics: &diagnostics)
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> BrowserToolbarButtonsSetting {
        guard let value = root.value(at: configPath) else { return fallback }
        let id = configPath.joined(separator: ".")
        guard case .array(let items) = value else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: id, message: "expected an array of button ids"))
            return fallback
        }
        let ids = items.compactMap(\.stringValue).filter(buttonIDs.contains)
        if ids.count != items.count {
            let known = buttonIDs.map { "\"\($0)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: id, message: "expected button ids: \(known)"))
        }
        return BrowserToolbarButtonsSetting(pinned: buttonIDs.filter(ids.contains))
    }

    /// The list with `id` pinned or unpinned, in toolbar order.
    public func toggling(_ id: String) -> BrowserToolbarButtonsSetting {
        let next = pinned.contains(id) ? pinned.filter { $0 != id } : pinned + [id]
        return BrowserToolbarButtonsSetting(pinned: Self.buttonIDs.filter(next.contains))
    }

    /// The value to write: nil (remove the key) when it is the default.
    public var configValue: JSONValue? {
        self == Self.fallback ? nil : .array(pinned.map(JSONValue.string))
    }

    static func descriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            configPath, section: .browser, group: group,
            title: SettingsText.keyed("settings.browser.toolbarButtons", "Toolbar Buttons"),
            help: SettingsText.keyed("settings.browser.toolbarButtons.help",
                                     "Buttons shown next to the address bar. The rest are in the More menu, where Show in Toolbar pins them back."),
            kind: .choiceSet(choices), default: .array(fallback.pinned.map(JSONValue.string)),
            keywords: ["toolbar", "buttons", "pin", "more", "extensions", "devtools", "bookmarks"]
        )
    }

    /// One switch per button on the Settings page, in toolbar order.
    static var choices: [SettingChoice] {
        [
            SettingChoice("media", SettingsText.keyed("settings.browser.toolbarButtons.media", "Media Controls")),
            SettingChoice("zoom", SettingsText.keyed("settings.browser.toolbarButtons.zoom", "Zoom Level")),
            SettingChoice("favorites", SettingsText.keyed("settings.browser.toolbarButtons.favorites", "Bookmarks")),
            SettingChoice("downloads", SettingsText.keyed("settings.browser.toolbarButtons.downloads", "Downloads")),
            SettingChoice("designMode", SettingsText.keyed("settings.browser.toolbarButtons.designMode", "Design Mode")),
            SettingChoice("profile", SettingsText.keyed("settings.browser.toolbarButtons.profile", "Browser Profile")),
            SettingChoice("theme", SettingsText.keyed("settings.browser.toolbarButtons.theme", "Browser Theme")),
            SettingChoice("devTools", SettingsText.keyed("settings.browser.toolbarButtons.devTools", "Developer Tools")),
        ]
    }
}

extension BrowserToolbarButtonsSetting {
    /// The pinned buttons the app applies: the effective root, so a managed value decides.
    @MainActor public static func current(_ settings: SettingsController) -> BrowserToolbarButtonsSetting {
        read(settings.snapshot.root)
    }
}
