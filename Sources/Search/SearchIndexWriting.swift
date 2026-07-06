import Foundation

protocol SearchIndexWriting: Actor {
    func upsert(_ document: SearchIndexDocument) throws
    func deleteDocument(id: String) throws
    func deleteDocuments(idPrefix: String) throws
    func deletePanel(_ panelID: UUID) throws
    func deleteWorkspace(_ workspaceID: UUID) throws
}
