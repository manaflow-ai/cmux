import AppKit

/// cmux: where a clicked attachment opens (the user, 2026-10-20: a picture or video a Chief sent
/// opens in cmux's pane on the right). The store's bytes have no extension, so the file page could
/// not tell their type: a copy under the attachment's own name (`<folder>/open/<hash>/<name>`)
/// goes to the host's `onAppLink` as a path link. A name never leaves its folder (only its last
/// path component is used; "" and ".." become "file").
struct HomeAttachmentOpen {
    /// The folder the copies live under (HomeMedia's folder in the app; a temp folder in tests).
    let folder: URL

    /// The copy of `original` named `name` for attachment `hash`, made once (a later call returns it).
    func namedCopy(of original: URL, name: String, hash: String) throws -> URL {
        let leaf = (name as NSString).lastPathComponent
        let safe = leaf.isEmpty || leaf == "." || leaf == ".." ? "file" : leaf
        let bucket = hash.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        let directory = folder.appendingPathComponent("open").appendingPathComponent(bucket.isEmpty ? "_" : bucket)
        let target = directory.appendingPathComponent(safe)
        let files = FileManager.default
        if files.fileExists(atPath: target.path) { return target }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try files.linkItem(at: original, to: target)
        } catch {
            try files.copyItem(at: original, to: target)
        }
        return target
    }
}

extension HomeAttachmentOpen {
    /// cmux: opens `file` in `host` (``HomeFileHost``: cmux beside Home, never Finder), else
    /// through the host's path-link opener (`onAppLink`), else with the system.
    @MainActor static func open(_ file: URL, host: HomeFileHost?, appLink: ((URL) -> Void)? = nil) {
        if let host { host.open(file) } else if let appLink { appLink(file) } else { NSWorkspace.shared.open(file) }
    }

    /// The attachment's menu rows: the host's file menu, or Open in Default App (`fallback`).
    @MainActor static func menuItems(name: String, host: HomeFileHost?, resolve: @escaping @MainActor @Sendable () async -> URL?,
                                     fallback: @escaping () -> Void) -> [NSMenuItem] {
        if let host { return host.menuItems(forFileNamed: name, resolve: resolve) }
        return [MenuAction(title: CmuxStrings.openInDefaultApp, symbol: "arrow.up.forward.app", fallback)]
    }
}
