public import AppKit

/// Where the files of the person's last native drop on a chat page, or paste into it, are on this
/// Mac. WebKit gives the page a dropped or pasted file's name and bytes, never its path, and a
/// folder's bytes can't be read at all. The view records the file URLs the drop's or paste's
/// pasteboard holds as it hands the drop or paste to WebKit, and the page asks for them right after
/// (`chat.attach.dropped {kind, names}`): a chat on this Mac then sends a folder, or a file no
/// prompt block takes, as a link to where it is instead of a copy. Page script can make neither a
/// native drop nor a paste of files, so it can't fill this.
///
/// Each record answers once, within ``lifetime``, and only for the same files: as many as the page
/// names, with the same names in any order. Any other ask uses it up and answers nothing.
public final class AgentPaneDroppedPaths {
    /// Which gesture brought the files in. A drop's record and a paste's are kept apart, so one never
    /// answers for the other.
    public nonisolated enum Kind: String, Sendable {
        case drop, paste
    }

    /// How long after the drop or paste the page may ask: it asks as soon as it has read the files.
    public nonisolated static let lifetime: TimeInterval = 5
    /// The most files one ask names.
    public nonisolated static let maximumNames = 100

    private var held: [Kind: (urls: [URL], at: TimeInterval)] = [:]
    private let now: @MainActor () -> TimeInterval

    public init(now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// Records the file URLs a drop or paste brought in, in place of the last ones of that kind; none
    /// clears it. Finder may put a file reference URL (`file:///.file/id=…`) on the pasteboard: it is
    /// kept as the file's path.
    public func stash(_ urls: [URL], kind: Kind) {
        let paths = urls.map { url in (url as NSURL).isFileReferenceURL() ? (url as NSURL).filePathURL ?? url : url }
        held[kind] = paths.isEmpty ? nil : (paths, now())
    }

    /// The recorded URLs of `kind` for the files `names` names (WebKit's `File.name`, the URL's last
    /// component), in the order of `names`; nil when there are none, they are older than
    /// ``lifetime``, or they are other files. Either way the record is used up.
    public func take(_ kind: Kind, names: [String]) -> [URL]? {
        guard let record = held.removeValue(forKey: kind), now() - record.at <= Self.lifetime,
              record.urls.count == names.count else { return nil }
        // WebKit hands the page the pasteboard's files in its order: a folder and a zip of the same
        // name (both `name.zip` to the page) stay apart.
        if zip(record.urls, names).allSatisfy(Self.named) { return record.urls }
        var left = record.urls
        var picked: [URL] = []
        for name in names {
            guard let index = left.firstIndex(where: { Self.named($0, name) }) else { return nil }
            picked.append(left.remove(at: index))
        }
        return picked
    }

    /// Whether WebKit names the file at `url` `name`. String equality is canonical: a name WebKit
    /// and the file system hold in different Unicode forms (é as one scalar or two) is the same
    /// name. WebKit names a folder (or a package such as an `.app`) `<name>.zip` with type
    /// `application/zip`, the archive it would make of it (FileCocoa.mm's replaced file), so that
    /// name is the folder's too.
    private static func named(_ url: URL, _ name: String) -> Bool {
        let last = url.lastPathComponent
        return name == last || name == last + ".zip"
    }

    /// A name the page may ask for: one a folder holds (``AgentPaneUpload/isFileName(_:)``), a dot
    /// file or folder (`.github`, `.env`) too, since it is only compared with the dropped files'.
    nonisolated static func isAskedName(_ name: String) -> Bool {
        AgentPaneUpload.isFileName(name.hasPrefix(".") ? String(name.dropFirst()) : name)
    }

    /// The file URLs `pasteboard` holds (Finder's copied or dragged files and folders); none for text
    /// or a picture.
    public static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
