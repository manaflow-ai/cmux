import Foundation
import UniformTypeIdentifiers

/// Internal workspace-sidebar drag payload for reordering and cross-window moves.
struct SidebarTabDragPayload {
    static let typeIdentifier = "com.cmux.sidebar-tab-reorder"
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]
    static let prefix = "cmux.sidebar-tab."

    let tabId: UUID

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = "\(Self.prefix)\(tabId.uuidString)"
        let data = Data(payload.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: Self.typeIdentifier, visibility: .ownProcess) { completion in
            // Data is already materialized, so a synchronous pasteboard request
            // never waits on work scheduled back to the main actor.
            completion(data, nil)
            return nil
        }
        return provider
    }
}
