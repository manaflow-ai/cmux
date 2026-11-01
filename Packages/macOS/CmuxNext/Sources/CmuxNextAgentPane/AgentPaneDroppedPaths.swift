public import AppKit
import CmuxNextWakeups

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
    /// answers for the other. `choose`: the person's pick in the page's file input (+ > Attach files,
    /// ``PageOpenPanel``): a chat on this Mac links the picked files where they are, as it does a
    /// Finder drop, instead of streaming a copy of each (a several-GB video took minutes and failed
    /// once the pick outlived the gesture's lifetime; Leo, 2026-10-31: "video attachments (big
    /// attachments?) still sucks").
    public nonisolated enum Kind: String, Sendable {
        case drop, paste, choose
    }

    /// How long after the drop or paste the page may ask: it asks as soon as it has read the files.
    public nonisolated static let lifetime: TimeInterval = 5
    /// The most files one ask names.
    public nonisolated static let maximumNames = 100

    struct Item {
        var url: URL
        var needsSnapshot: Bool
        var snapshot: AgentPaneRecordingSnapshot?
    }

    private struct Record {
        var items: [Item]
        var at: TimeInterval
        var id: UUID
        var expiry: DemandTimer
    }

    private var held: [Kind: Record] = [:]
    /// What the last drop's or paste's pasteboard said about where its contents came from, for the
    /// page's `chat.attach.source` (``AgentPaneModel/attachSource(_:names:apps:)``): its file URLs,
    /// how many items it held, and the app it says wrote it. Kept apart from ``held``, since each
    /// record answers one ask.
    private var sourced: [Kind: (urls: [URL], items: Int, claimed: String?, at: TimeInterval, madeAt: TimeInterval)] = [:]
    private let now: @MainActor () -> TimeInterval
    /// The Mac's own clock (seconds since 1970): what the page's `Date.now()` reads too, so a source
    /// record and the page's gesture can be put in order (``source(_:names:gestureAt:)``).
    private let wall: @MainActor () -> TimeInterval
    /// How far the page's gesture time may read before its record's: the page reads the same clock
    /// (`Date.now()`) after the record was made, cut to whole milliseconds, so it is at most that much
    /// earlier. No more: an older gesture's late ask a few milliseconds before a newer record of its
    /// kind must not take it.
    nonisolated static let gestureSlack: TimeInterval = 0.001
    /// Exact copies of the person's recording drops, never their parent folders. These remain
    /// usable by this pane's existing file open/drag actions after the preview path disappears.
    private(set) var retainedPaths: [String] = []
    /// Invalidates async drop work when the pane switches to a different chat.
    private(set) var generation = UUID()

    public init(now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                wall: @escaping @MainActor () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.now = now
        self.wall = wall
    }

    /// Records the file URLs a drop or paste brought in, in place of the last ones of that kind; none
    /// clears it. Finder may put a file reference URL (`file:///.file/id=…`) on the pasteboard: it is
    /// kept as the file's path.
    public func stash(_ urls: [URL], kind: Kind) {
        held.removeValue(forKey: kind)?.expiry.cancel()
        let paths = urls.map { url in (url as NSURL).isFileReferenceURL() ? (url as NSURL).filePathURL ?? url : url }
        guard !paths.isEmpty, paths.count <= Self.maximumNames else { return }
        // A preview's file of any size is pinned: its copy is a clone, never read into memory.
        let items = paths.map { url -> Item in
            let needsSnapshot = AgentPaneRecordingSnapshot.needsSnapshot(url)
            return Item(url: url, needsSnapshot: needsSnapshot, snapshot: needsSnapshot ? AgentPaneRecordingSnapshot.pin(url) : nil)
        }
        let id = UUID(), expiry = DemandTimer(owner: "agent-pane.droppedPaths.expiry")
        held[kind] = Record(items: items, at: now(), id: id, expiry: expiry)
        expiry.schedule(after: .seconds(Self.lifetime)) { @MainActor [weak self] in
            guard self?.held[kind]?.id == id else { return }
            self?.held[kind] = nil
        }
    }

    /// Records what a drop's or paste's pasteboard said, with its file URLs and its item count:
    /// where its contents came from, as only the person's own drop or paste can say
    /// (``source(_:names:)``). One with no files and no claim says nothing, and clears the record.
    /// `madeAt` (seconds since 1970): when the gesture happened, for one recorded after its page took
    /// it (a Chromium drop, reported by the page's drop message: the drag's entry); now otherwise.
    public func stashSource(_ urls: [URL], items: Int, claimed: String?, kind: Kind, madeAt: TimeInterval? = nil) {
        let paths = urls.map { url in (url as NSURL).isFileReferenceURL() ? (url as NSURL).filePathURL ?? url : url }
        sourced[kind] = paths.isEmpty && claimed == nil ? nil : (paths, max(items, paths.count), claimed, now(), madeAt ?? wall())
    }

    /// What the last drop or paste of `kind` said, for the files `names` names, within ``lifetime``:
    /// the file URLs among them, and its claim. Only an ask for that gesture's own files answers,
    /// and uses the record up: no more files than the pasteboard held items, and every file URL it
    /// held named (a drop of files and pictures names both). Any other ask answers nothing and
    /// leaves the record for the page's own ask. `gestureAt` (the page's clock when it took the
    /// gesture, seconds since 1970): an ask for a gesture taken before the record was made is for an
    /// older gesture, one that reached the host late, so it answers nothing and leaves the newer
    /// gesture its record. Nil (an older page) skips that check.
    func source(_ kind: Kind, names: [String], gestureAt: TimeInterval? = nil) -> (urls: [URL], claimed: String?)? {
        guard let record = sourced[kind] else { return nil }
        if let gestureAt, gestureAt + Self.gestureSlack < record.madeAt { return nil }
        guard now() - record.at <= Self.lifetime else {
            sourced[kind] = nil
            return nil
        }
        guard !names.isEmpty, names.count <= record.items else { return nil }
        var left = record.urls
        var picked: [URL] = []
        for name in names {
            guard let index = left.firstIndex(where: { Self.named($0, name) }) else { continue }
            picked.append(left.remove(at: index))
        }
        guard left.isEmpty else { return nil }
        sourced[kind] = nil
        return (picked, record.claimed)
    }

    /// The recorded URLs of `kind` for the files `names` names (WebKit's `File.name`, the URL's last
    /// component), in the order of `names`; nil when there are none, they are older than
    /// ``lifetime``, or they are other files. Either way the record is used up.
    public func take(_ kind: Kind, names: [String]) -> [URL]? {
        guard let items = takeItems(kind, names: names), !items.contains(where: \.needsSnapshot) else { return nil }
        return items.map(\.url)
    }

    /// The same one-shot record with the pinned recording bytes for the model's local upload.
    func takeItems(_ kind: Kind, names: [String]) -> [Item]? {
        guard let record = held.removeValue(forKey: kind) else { return nil }
        record.expiry.cancel()
        guard now() - record.at <= Self.lifetime, record.items.count == names.count else { return nil }
        // WebKit hands the page the pasteboard's files in its order: a folder and a zip of the same
        // name (both `name.zip` to the page) stay apart.
        if zip(record.items, names).allSatisfy({ Self.named($0.0.url, $0.1) }) { return record.items }
        var left = record.items
        var picked: [Item] = []
        for name in names {
            guard let index = left.firstIndex(where: { Self.named($0.url, name) }) else { return nil }
            picked.append(left.remove(at: index))
        }
        return picked
    }

    /// Remembers only the trusted local upload owner's returned files, bounded to this pane's
    /// newest hundred copies. No parent directory becomes an allowed root.
    func retain(_ paths: [String]) {
        for path in paths {
            retainedPaths.removeAll { $0 == path }
            retainedPaths.append(path)
        }
        if retainedPaths.count > 100 { retainedPaths.removeFirst(retainedPaths.count - 100) }
    }

    /// A pane can move between chat sessions. Clear pending drops as well as already-retained
    /// copies so the next chat cannot consume or open the prior chat's recording.
    func clearForSessionChange() {
        generation = UUID()
        held.values.forEach { $0.expiry.cancel() }
        held.removeAll()
        sourced.removeAll()
        retainedPaths.removeAll()
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
