public import Foundation

/// Chromium's link, image and selection rows, replaced by the cmux rows
/// (`BrowserHitMenu` in the App) so both engines show one menu.
extension BrowserContextMenuItem {
    /// Chromium command ids (chrome/app/chrome_command_ids.h).
    enum ChromiumCommand {
        static let link: Set<Int> = [
            50100, // IDC_CONTENT_CONTEXT_OPENLINKNEWTAB
            50101, // IDC_CONTENT_CONTEXT_OPENLINKNEWWINDOW
            50102, // IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD
            50103, // IDC_CONTENT_CONTEXT_SAVELINKAS
            50104, // IDC_CONTENT_CONTEXT_COPYLINKLOCATION
            50107, // IDC_CONTENT_CONTEXT_COPYLINKTEXT
        ]
        static let image: Set<Int> = [
            50120, // IDC_CONTENT_CONTEXT_SAVEIMAGEAS
            50121, // IDC_CONTENT_CONTEXT_COPYIMAGELOCATION
            50122, // IDC_CONTENT_CONTEXT_COPYIMAGE
            50123, // IDC_CONTENT_CONTEXT_OPENIMAGENEWTAB
            50125, // IDC_CONTENT_CONTEXT_OPEN_ORIGINAL_IMAGE_NEW_TAB
        ]
        /// Only outside editable fields: there Chromium's Cut, Copy and
        /// Paste stay together.
        static let selection: Set<Int> = [
            50150, // IDC_CONTENT_CONTEXT_COPY
            50165, // IDC_CONTENT_CONTEXT_LOOK_UP
            50191, // IDC_CONTENT_CONTEXT_SEARCHWEBFOR
            50192, // IDC_CONTENT_CONTEXT_SEARCHWEBFORNEWTAB
        ]
    }

    /// Pure: Chromium's top-level `items` without the rows the cmux link,
    /// image and selection rows replace for `target`, with no leading,
    /// trailing or doubled separators. Extension, spelling, Inspect and
    /// every other row stay.
    public static func withoutHitItems(_ items: [BrowserContextMenuItem], for target: BrowserContextMenuTarget) -> [BrowserContextMenuItem] {
        var dropped = ChromiumCommand.link.union(ChromiumCommand.image)
        if !target.isEditable { dropped.formUnion(ChromiumCommand.selection) }
        var result: [BrowserContextMenuItem] = []
        for item in items where !(item.kind != .separator && dropped.contains(item.id)) {
            if item.kind == .separator, result.last.map({ $0.kind == .separator }) ?? true { continue }
            result.append(item)
        }
        if result.last?.kind == .separator { result.removeLast() }
        return result
    }
}

extension BrowserContextMenuTarget {
    /// The `contextmenu` event's report from WebKit's hit script
    /// (`WebKitContextHit`): `{link, linkText, image, selection, editable}`.
    /// Nil for anything else.
    public static func webKitHit(_ body: Any) -> BrowserContextMenuTarget? {
        guard let object = body as? [String: Any] else { return nil }
        func url(_ key: String) -> URL? {
            (object[key] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        }
        let image = url("image")
        return BrowserContextMenuTarget(linkURL: url("link"), linkText: object["linkText"] as? String ?? "", sourceURL: image,
                                        imageURL: image, selection: object["selection"] as? String ?? "",
                                        isEditable: object["editable"] as? Bool ?? false)
    }
}
