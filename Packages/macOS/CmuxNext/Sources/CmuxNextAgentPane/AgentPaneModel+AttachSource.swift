import AppKit

extension AgentPaneModel {
    /// Where the files of the person's drop or paste came from (`chat.attach.source {kind, names}`,
    /// ``AttachmentSource``): `{sources: [source | null]}` in the order of `names`. A file the
    /// pasteboard names by URL answers its own metadata's source (AttachmentSourceFiles.swift), read
    /// off the main actor; any other (a pasted picture, an image dragged from a page) answers the
    /// gesture's: for a paste, the app that put the contents on the pasteboard
    /// (``AttachmentPasteboardOrigin``), for a drop the app in front, which is the one the drag
    /// came from (macOS does not bring a drop's target to the front). A drop while cmux is in front
    /// came from somewhere this cannot tell, and answers no source. A chat on another machine gets
    /// the gesture's only: this Mac's files are never read for it (cx-k21v).
    func attachSource(_ kind: AgentPaneDroppedPaths.Kind, names: [String], apps: AttachmentSourceApps = .live) async -> [String: Any] {
        let pasteboard = kind == .paste ? NSPasteboard.general : NSPasteboard(name: .drag)
        let gesture: AttachmentSource? = switch kind {
        case .paste: AttachmentPasteboardOrigin.shared.source(apps: apps)
        case .drop: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            .flatMap { $0 == apps.ownBundleId() ? nil : AttachmentPasteboardOrigin.source(bundleId: $0, apps: apps) }
        }
        let urls = remoteChat ? [] : AgentPaneDroppedPaths.fileURLs(on: pasteboard).map { url in
            (url as NSURL).isFileReferenceURL() ? (url as NSURL).filePathURL ?? url : url
        }
        let sources = await Task.detached(priority: .userInitiated) {
            Self.sources(for: names, urls: urls, gesture: gesture) { AttachmentSource.source(of: $0, apps: apps) }
        }.value
        return AgentPaneReply.success(["sources": sources.map { $0?.json ?? NSNull() as Any }])
    }

    /// Each name's source: the file of that name among `urls` (WebKit's name for it, a folder's with
    /// `.zip`), each file used once, by its metadata (`file`); else the gesture's.
    nonisolated static func sources(for names: [String], urls: [URL], gesture: AttachmentSource?,
                                    file: (URL) -> AttachmentSource?) -> [AttachmentSource?] {
        var left = urls
        return names.map { name in
            guard let index = left.firstIndex(where: { $0.lastPathComponent == name || $0.lastPathComponent + ".zip" == name }) else {
                return gesture
            }
            return file(left.remove(at: index)) ?? gesture
        }
    }
}
