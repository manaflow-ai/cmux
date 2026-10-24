import CmuxNextDesign
import Foundation

/// The file pages' quit documents, one per canonical path, registered with the quit hook while a
/// tab that edited the file still shows it. Each such tab is a holder; the document leaves with
/// the last one.
final class FileQuitDocuments {
    private let drafts: RecoveryDraftStore
    private let registry: QuitUnsavedRegistry
    private let participantID: (URL) -> String
    private var documents: [String: (document: FileQuitDocument, registration: QuitUnsavedRegistration, holders: Set<String>)] = [:]

    /// The app's (`AppServices.fileQuitDocuments`) is shared by both file pages, so a markdown tab
    /// and an editor tab on one file are one document.
    init(drafts: RecoveryDraftStore, registry: QuitUnsavedRegistry,
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
