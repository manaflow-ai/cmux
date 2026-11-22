import AppKit

extension AgentPaneModel {
    /// Where the files of the person's drop or paste came from (`chat.attach.source {kind, names}`,
    /// ``AttachmentSource``): `{sources: [source | null]}` in the order of `names`.
    ///
    /// It answers only from what the person's own native drop or paste, or pick in the file input
    /// (``PageOpenPanel``), recorded as it reached the page
    /// (``AgentPaneDroppedPaths/stashSource(_:items:claimed:kind:)``), once, within its lifetime, and
    /// only for that gesture's own files (``AgentPaneDroppedPaths/source(_:names:)``). Page script
    /// can make none of them, so it can't ask about a pasteboard or file the person did not bring. A
    /// file the record names by URL answers its own metadata's source (AttachmentSourceFiles.swift),
    /// read off the main actor. Any other (a pasted picture, an image dragged from a page) answers the
    /// app the pasteboard said wrote it (`org.nspasteboard.source`), else none. A chat on another
    /// machine gets only that claim: this Mac's files are never read for it (cx-k21v).
    func attachSource(_ kind: AgentPaneDroppedPaths.Kind, names: [String], gestureAt: TimeInterval? = nil,
                      apps: AttachmentSourceApps = .live) async -> [String: Any] {
        guard let record = droppedPaths.source(kind, names: names, gestureAt: gestureAt) else {
            return AgentPaneReply.success(["sources": names.map { _ in NSNull() as Any }])
        }
        let claimed = record.claimed.flatMap { AttachmentSource.source(bundleId: $0, apps: apps) }
        let urls = remoteChat ? [] : record.urls
        let sources = await Task.detached(priority: .userInitiated) {
            Self.sources(for: names, urls: urls, claimed: claimed) { AttachmentSource.source(of: $0, apps: apps) }
        }.value
        // Only these apps' icons are drawn (`attachment.sourceIcon`).
        for bundleId in sources.compactMap({ $0?.bundleId }) { sourceIcons.noteAnswered(bundleId) }
        return AgentPaneReply.success(["sources": sources.map { $0?.json ?? NSNull() as Any }])
    }

    /// Each name's source: the file of that name among `urls` (WebKit's name for it, a folder's with
    /// `.zip`), each file used once, by its metadata (`file`); else the pasteboard's `claimed` writer.
    nonisolated static func sources(for names: [String], urls: [URL], claimed: AttachmentSource?,
                                    file: (URL) -> AttachmentSource?) -> [AttachmentSource?] {
        var left = urls
        return names.map { name in
            guard let index = left.firstIndex(where: { $0.lastPathComponent == name || $0.lastPathComponent + ".zip" == name }) else {
                return claimed
            }
            return file(left.remove(at: index)) ?? claimed
        }
    }
}
