import Foundation
import UniformTypeIdentifiers

/// Internal workspace-sidebar drag payload for reordering and cross-window moves.
struct SidebarTabDragPayload {
    static let typeIdentifier = "com.cmux.sidebar-tab-reorder"
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]
    static let prefix = "cmux.sidebar-tab."

    let tabId: UUID

    /// Recovers the dragged workspace id from a drag pasteboard string. The
    /// pasteboard is the one identity that survives for the whole native drag
    /// session, so drop paths use it to re-arm drag state that was cleared
    /// mid-flight (for example by the app-resign failsafe).
    static func workspaceId(fromPasteboardString raw: String?) -> UUID? {
        guard let raw, raw.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(raw.dropFirst(prefix.count)))
    }

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
