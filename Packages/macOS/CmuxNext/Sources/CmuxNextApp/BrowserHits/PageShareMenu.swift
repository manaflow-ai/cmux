import AppKit

/// Share… in a page's right-click menu (cx-k9go, Safari and Chrome): the
/// system share menu for the page's address. Only web addresses are shared
/// (never cmux:// pages or file URLs).
@MainActor
enum PageShareMenu {
    /// The picker behind the open menu's Share… row (AppKit keeps only a weak reference).
    private static var picker: NSSharingServicePicker?

    static func items(for url: URL?) -> [NSMenuItem] {
        guard let url, url.scheme == "http" || url.scheme == "https" else { return [] }
        let picker = NSSharingServicePicker(items: [url])
        Self.picker = picker
        return [.separator(), picker.standardShareMenuItem]
    }
}
