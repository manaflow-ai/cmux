import CmuxNextDesign
import Foundation

/// One file page document in the R96 quit hook: shared by every tab that shows the file, unsaved
/// from the first edit a page reports (`cmux.<page>.edited`), with a recovery draft written on
/// every edit through `RecoveryDraftStore`. The quit flush asks each page to save first
/// (`cmux.<page>.flush`); a document still unsaved after that is written by the host from the last
/// text a page reported, on the base hash that text was edited from, so a quit never writes over a
/// change made on disk.
final class FileQuitDocument: QuitUnsavedParticipant {
    let url: URL
    let quitParticipantID: String
    private let drafts: RecoveryDraftStore
    private let writable: () -> Bool
    private(set) var hasUnsavedChanges = false
    /// The last text a page reported, and the file hash it was edited from.
    private(set) var latestText: String?
    private(set) var baseHash: String?
    private var flushers: [UUID: () async -> Bool] = [:]
    private var work: [Task<Void, Never>] = []

    /// `id` defaults to `QuitParticipantID.file(path:)` (host "local"); tests pass a malformed one.
    init(url: URL, id: String? = nil, drafts: RecoveryDraftStore, writable: @escaping () -> Bool) {
        self.url = url
        quitParticipantID = id ?? QuitParticipantID.file(path: url.path)
        self.drafts = drafts
        self.writable = writable
    }

    var quitTitle: String { "\(url.lastPathComponent) (\(url.deletingLastPathComponent().lastPathComponent))" }
    var quitFlushDeadline: Duration { .seconds(3) }

    /// A page's edit: unsaved unless the text is the file's again; the draft follows.
    @discardableResult
    func edited(text: String, baseHash: String?) -> RecoveryDraftAcceptance {
        latestText = text
        self.baseHash = baseHash
        guard FileDocument.hash(Data(text.utf8)) != baseHash else {
            markClean()
            return .kept
        }
        // The base is the edit's: the launch check compares the file with what the page edited.
        let accepted = drafts.update(id: quitParticipantID, title: quitTitle, contents: Data(text.utf8), filePath: url.path,
                                     base: baseHash.map { RecoveryDraftBase(contentHash: $0) })
        if accepted != .invalidID { hasUnsavedChanges = true }
        return accepted
    }

    /// A normal save wrote `hash`: clean when it is the last reported text.
    func saved(hash: String) {
        baseHash = hash
        if let latestText, FileDocument.hash(Data(latestText.utf8)) != hash { return }
        markClean()
    }

    /// The last tab closed with edits that did not save: they are dropped, and so is the draft.
    func closedWithoutSaving() {
        markClean()
    }

    /// A page that can save the document now; returns whether edits are still unsaved.
    func addFlusher(_ flush: @escaping () async -> Bool) -> () -> Void {
        let id = UUID()
        flushers[id] = flush
        return { [weak self] in self?.flushers[id] = nil }
    }

    /// Draft removals still running (tests await them).
    func settled() async {
        let running = work
        work.removeAll()
        for task in running { await task.value }
    }

    // MARK: QuitUnsavedParticipant

    func flushForQuit() async throws {
        // Each page saves through the host first (a save marks the document clean).
        for flush in Array(flushers.values) where hasUnsavedChanges {
            _ = await flush()
        }
        guard hasUnsavedChanges, let text = latestText else { return }
        let name = url.lastPathComponent
        do {
            let result = try await Self.write(text, to: url, baseHash: baseHash, inWorkspace: writable())
            baseHash = result.hash
            hasUnsavedChanges = false
        } catch .readOnly {
            throw QuitFlushError.readOnly(name)
        } catch .conflict, .deleted {
            throw QuitFlushError.conflict(name)
        } catch .failed(let reason) {
            throw QuitFlushError.failed(reason)
        }
    }

    func discardForQuit() async {
        hasUnsavedChanges = false
        latestText = nil
    }

    private func markClean() {
        hasUnsavedChanges = false
        let drafts = drafts, id = quitParticipantID
        work.append(Task { await drafts.remove(id: id) })
    }

    @concurrent private static func write(_ text: String, to url: URL, baseHash: String?,
                                          inWorkspace: Bool) async throws(FileSaveFailure) -> FileSaveResult {
        try FileDocument.save(text, to: url, baseHash: baseHash, inWorkspace: inWorkspace)
    }
}

/// The file pages' quit documents, one per canonical path, registered with the quit hook while a
/// tab that edited the file still shows it. Each such tab is a holder; the document leaves with
/// the last one.
final class FileQuitDocuments {
    /// The app's: both file pages share it, so a markdown tab and an editor tab on one file are one
    /// document.
    static let shared = FileQuitDocuments()
    private let drafts: RecoveryDraftStore
    private let registry: QuitUnsavedRegistry
    private let participantID: (URL) -> String
    private var documents: [String: (document: FileQuitDocument, registration: QuitUnsavedRegistration, holders: Set<String>)] = [:]

    init(drafts: RecoveryDraftStore = .shared, registry: QuitUnsavedRegistry = .shared,
         participantID: @escaping (URL) -> String = { QuitParticipantID.file(path: $0.path) }) {
        self.drafts = drafts
        self.registry = registry
        self.participantID = participantID
    }

    /// The document of `url`, held by `holder`; nil when the quit hook refused its id (an inactive
    /// registration), which the caller reports as `invalidID`.
    func document(for url: URL, holder: String, writable: @escaping () -> Bool) -> FileQuitDocument? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let existing = documents[path] {
            documents[path]?.holders.insert(holder)
            return existing.document
        }
        let file = URL(fileURLWithPath: path)
        let document = FileQuitDocument(url: file, id: participantID(file), drafts: drafts, writable: writable)
        let registration = registry.register(document)
        guard registration.isActive else { return nil }
        documents[path] = (document, registration, [holder])
        return document
    }

    func existing(_ url: URL) -> FileQuitDocument? {
        documents[url.standardizedFileURL.resolvingSymlinksInPath().path]?.document
    }

    /// `holder` no longer shows `url`. With no holder left, edits that did not save are dropped and
    /// the draft goes.
    func release(_ url: URL, holder: String) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        documents[path]?.holders.remove(holder)
        guard documents[path]?.holders.isEmpty == true, let entry = documents.removeValue(forKey: path) else { return }
        if entry.document.hasUnsavedChanges { entry.document.closedWithoutSaving() }
        entry.registration.cancel()
    }
}

/// Recovered drafts that belong to the file pages: local files only (a draft never writes a remote
/// file into a local one).
nonisolated enum FilePageRecovery {
    static func document(of draft: RecoveryDraft) -> URL? {
        guard let parts = QuitParticipantID.parse(draft.id), parts.host == QuitParticipantID.localHost,
              draft.host == QuitParticipantID.localHost, draft.filePath == parts.path else { return nil }
        return URL(fileURLWithPath: parts.path)
    }

    /// What a recovered draft opens as: its file, its text, and whether the file differs from the
    /// draft's base (or the draft has no base, or the file is gone). The restore handler gets no
    /// "changed on disk" flag (R96 v2); this reads the file and never writes it.
    struct Restore: Equatable {
        let url: URL
        let text: String
        let conflict: Bool
    }

    @concurrent static func restore(_ draft: RecoveryDraft) async -> Restore? {
        guard let url = document(of: draft) else { return nil }
        let current = (try? Data(contentsOf: url)).map(FileDocument.hash) // concurrency-allow: @concurrent, off the main actor
        let conflict = current == nil || draft.base?.contentHash == nil || current != draft.base?.contentHash
        return Restore(url: url, text: String(decoding: draft.contents, as: UTF8.self), conflict: conflict)
    }
}
