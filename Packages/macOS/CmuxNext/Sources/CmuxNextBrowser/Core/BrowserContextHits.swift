public import Foundation

/// Chromium's link, image and selection rows, replaced by the cmux rows
/// (`BrowserHitMenu` in the App) so both engines show one menu.
extension BrowserContextMenuItem {
    /// Chromium command ids (chrome/app/chrome_command_ids.h) that a cmux
    /// row replaces, with the catalog action of that row.
    enum ChromiumCommand {
        static let link: [Int: String] = [
            50100: "browser.link.openInNewTab", // IDC_CONTENT_CONTEXT_OPENLINKNEWTAB
            50101: "browser.link.openInNewWindow", // IDC_CONTENT_CONTEXT_OPENLINKNEWWINDOW
            50102: "browser.link.openInIncognitoWindow", // IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD
            50103: "browser.link.saveAs", // IDC_CONTENT_CONTEXT_SAVELINKAS
            50104: "browser.link.copy", // IDC_CONTENT_CONTEXT_COPYLINKLOCATION
        ]
        /// Only when cmux read the link's text: otherwise Chromium's row
        /// (which knows the text) stays.
        static let linkText: [Int: String] = [
            50107: "browser.link.copyText", // IDC_CONTENT_CONTEXT_COPYLINKTEXT
        ]
        /// Only for an image with an address: a canvas uses the same Save
        /// and Copy ids, and no cmux row replaces them there.
        static let image: [Int: String] = [
            50120: "browser.image.saveAs", // IDC_CONTENT_CONTEXT_SAVEIMAGEAS
            50121: "browser.image.copyAddress", // IDC_CONTENT_CONTEXT_COPYIMAGELOCATION
            50122: "browser.image.copy", // IDC_CONTENT_CONTEXT_COPYIMAGE
            50123: "browser.image.openInNewTab", // IDC_CONTENT_CONTEXT_OPENIMAGENEWTAB
            50125: "browser.image.openInNewTab", // IDC_CONTENT_CONTEXT_OPEN_ORIGINAL_IMAGE_NEW_TAB
        ]
        /// Only for a selection outside editable fields (there Chromium's
        /// Cut, Copy and Paste stay together) that is not only white space
        /// (cmux shows no selection rows for it).
        static let selection: [Int: String] = [
            50150: "browser.selection.copy", // IDC_CONTENT_CONTEXT_COPY
            50165: "browser.selection.lookUp", // IDC_CONTENT_CONTEXT_LOOK_UP
            50191: "browser.selection.search", // IDC_CONTENT_CONTEXT_SEARCHWEBFOR
            50192: "browser.selection.search", // IDC_CONTENT_CONTEXT_SEARCHWEBFORNEWTAB
        ]

        /// The Chromium rows a cmux row replaces for `target`, by id, with
        /// the replacing action.
        static func replaced(for target: BrowserContextMenuTarget) -> [Int: String] {
            var result: [Int: String] = [:]
            func add(_ table: [Int: String]) { result.merge(table) { first, _ in first } }
            if target.linkURL != nil {
                add(link)
                if !target.linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(linkText) }
            }
            if target.imageURL != nil { add(image) }
            if !target.isEditable, !target.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(selection) }
            return result
        }
    }

    /// Pure: the Chromium command ids that cmux rows replace for `target`,
    /// each with the catalog action (`ActionID`) of the row that replaces it.
    public static func replacedChromiumRows(for target: BrowserContextMenuTarget) -> [Int: String] {
        ChromiumCommand.replaced(for: target)
    }

    /// Pure: Chromium's top-level `items` without the rows the cmux link,
    /// image and selection rows replace for `target` (a row is dropped only
    /// when the cmux row that replaces it shows), with no leading, trailing
    /// or doubled separators. Extension, spelling, Inspect, canvas and every
    /// other row stay.
    public static func withoutHitItems(_ items: [BrowserContextMenuItem], for target: BrowserContextMenuTarget) -> [BrowserContextMenuItem] {
        let dropped = ChromiumCommand.replaced(for: target)
        var result: [BrowserContextMenuItem] = []
        for item in items where !(item.kind != .separator && dropped[item.id] != nil) {
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
