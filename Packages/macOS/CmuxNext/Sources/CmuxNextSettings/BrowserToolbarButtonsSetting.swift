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
///
/// The path, the default list (`fallback`) and every button the list may name (`values`, in
/// toolbar order) come from schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
public nonisolated struct BrowserToolbarButtonsSetting: Sendable, Hashable {
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
        guard let value = root.value(at: configPath) else { return BrowserToolbarButtonsSetting(pinned: fallback) }
        let id = configPath.joined(separator: ".")
        guard case .array(let items) = value else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: id, message: "expected an array of button ids"))
            return BrowserToolbarButtonsSetting(pinned: fallback)
        }
        let ids = items.compactMap(\.stringValue).filter(values.contains)
        if ids.count != items.count {
            let known = values.map { "\"\($0)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: id, message: "expected button ids: \(known)"))
        }
        return BrowserToolbarButtonsSetting(pinned: values.filter(ids.contains))
    }

    /// The list with `id` pinned or unpinned, in toolbar order.
    public func toggling(_ id: String) -> BrowserToolbarButtonsSetting {
        let next = pinned.contains(id) ? pinned.filter { $0 != id } : pinned + [id]
        return BrowserToolbarButtonsSetting(pinned: Self.values.filter(next.contains))
    }

    /// The value to write: nil (remove the key) when it is the default.
    public var configValue: JSONValue? {
        pinned == Self.fallback ? nil : .array(pinned.map(JSONValue.string))
    }
}

extension BrowserToolbarButtonsSetting {
    /// The pinned buttons the app applies: the effective root, so a managed value decides.
    @MainActor public static func current(_ settings: SettingsController) -> BrowserToolbarButtonsSetting {
        read(settings.snapshot.root)
    }
}
