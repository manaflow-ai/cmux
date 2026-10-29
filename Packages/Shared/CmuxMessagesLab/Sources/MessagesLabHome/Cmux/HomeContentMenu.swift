import AppKit

/// cmux: the one builder of Home chat's right-click rows by content type. Every surface that shows
/// content (a message bubble, a quoted reply's preview, the message box's pictures, the reply card)
/// asks it for the rows of what is under the pointer, so Copy, Save As…, Open and link rows exist once
/// (the user, 2026-10-25: "make sure I can right click reply images, my own images, literally everything").
struct HomeContentMenu {
    /// Copy's string write: the general pasteboard; tests record it (the CI Macs' pasteboard server
    /// answers inconsistently, and the user's clipboard stays).
    var writeString: @MainActor (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// Opens a link (the host's opener: cmux's browser, or the system).
    var openLink: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Copy and Save As… for attachments.
    var attachmentRows = HomeAttachmentRows()
    /// The host's file menu (Open in Right Pane, Open With, Quick Look…); nil: Open in Default App.
    var fileHost: HomeFileHost?

    /// Copy: the selected words when `selection` has some, else the whole `text`.
    @MainActor func textItems(_ text: String, selection: String?) -> [NSMenuItem] {
        let words = selection.flatMap { $0.isEmpty ? nil : $0 } ?? text
        let write = writeString
        return [MenuAction(title: Strings.menuCopy) { write(words) }]
    }

    /// Open Link and Copy Link Address for `url`.
    @MainActor func linkItems(_ url: URL) -> [NSMenuItem] {
        let write = writeString, open = openLink
        return [
            MenuAction(title: CmuxStrings.openLink, symbol: "safari") { open(url) },
            MenuAction(title: CmuxStrings.copyLinkAddress, symbol: "link") { write(url.absoluteString) },
        ]
    }

    /// Copy (the file, and an image's pixels), Save As… and the open rows of an attachment named `name`.
    /// `resolve` fetches its local copy when a row runs; `fallback` opens it when there is no host.
    @MainActor func attachmentItems(name: String, resolve: @escaping @MainActor @Sendable () async -> URL?,
                                    fallback: @escaping () -> Void) -> [NSMenuItem] {
        var rows = attachmentRows.items(name: name, resolve: resolve)
        rows.append(.separator())
        rows += HomeAttachmentOpen.menuItems(name: name, host: fileHost, resolve: resolve, fallback: fallback)
        return rows
    }

    /// The rows of one message part, for a bubble or the quoted copy of one above a reply.
    /// A video's play row is the bubble's own (it plays in place). `links`: false when the caller
    /// already added the rows of the link under the pointer.
    @MainActor func partItems(_ part: Part, selection: String? = nil, links: Bool = true,
                              resolve: @escaping @MainActor @Sendable (Attachment) -> (@MainActor @Sendable () async -> URL?),
                              openAttachment: @escaping (Attachment) -> Void) -> [NSMenuItem] {
        var rows: [NSMenuItem] = []
        switch part {
        case let .text(text, _):
            rows += textItems(text, selection: selection)
        case let .link(raw, _, _, _, _):
            if links, let url = MarkdownLinkPolicy.url(raw) { rows += linkItems(url) }
            rows += textItems(raw, selection: nil)
        case let .attachment(a):
            rows += attachmentItems(name: a.fileName, resolve: resolve(a)) { openAttachment(a) }
        case let .location(lat, lon, title, subtitle):
            let text = [title, subtitle, "\(lat), \(lon)"].compactMap { $0 }.joined(separator: "\n")
            rows += textItems(text, selection: nil)
        case .custom:
            break
        }
        return rows
    }
}
