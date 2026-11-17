public import Foundation
public import MessagesLabHome

/// The cards a link chip shows from its URL alone (a file, a GitHub object), and a file's first
/// lines for its card (read off the main thread by the caller).
extension HomeLinkPreview {
    /// Lines a card shows at most.
    public nonisolated static let maxLines = 6
    /// Bytes of a file read for its first lines.
    nonisolated static let fileBytes = 4096

    /// A file's card: its name and folder.
    public static func file(_ url: URL, kind: HomeLinkChipKind) -> HomeLinkPreview {
        let path = url.standardizedFileURL.path
        return HomeLinkPreview(kind: kind, title: (path as NSString).lastPathComponent,
                               place: abbreviated((path as NSString).deletingLastPathComponent))
    }

    /// A GitHub object's card: its number (a commit's short sha, a run's id) and repository.
    public static func gitHub(_ url: URL, kind: HomeLinkChipKind) -> HomeLinkPreview {
        let parts = url.path.split(separator: "/").map(String.init)
        let id = parts.last ?? ""
        let title = kind == .commit ? String(id.prefix(10)) : kind == .run ? id : "#" + id
        return HomeLinkPreview(kind: kind, title: title, place: parts.prefix(2).joined(separator: "/"))
    }

    /// `path` with the home folder as `~`.
    public nonisolated static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A file's first non-empty lines (or a folder's first names); nil when it is gone.
    public nonisolated static func firstLines(_ path: String, folder: Bool) -> [String]? {
        if folder {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
            return Array(names.filter { !$0.hasPrefix(".") }.sorted().prefix(maxLines))
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: fileBytes)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard !text.contains("\u{0}") else { return [] }
        return Array(text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(maxLines))
    }
}
