import AppKit
import CmuxSidebar
import Foundation
import UniformTypeIdentifiers

/// Internal workspace-sidebar drag payload for reordering and cross-window moves.
struct SidebarTabDragPayload {
    static let typeIdentifier = SidebarWorkspaceDragSession.pasteboardTypeIdentifier
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]
    static let prefix = SidebarWorkspaceDragSession.pasteboardPrefix

    let tabId: UUID
    let sessionId: UUID?

    init(tabId: UUID, sessionId: UUID? = nil) {
        self.tabId = tabId
        self.sessionId = sessionId
    }

    var pasteboardValue: String {
        guard let sessionId else {
            return "\(Self.prefix)\(tabId.uuidString)"
        }
        return "\(Self.prefix)\(tabId.uuidString)#\(sessionId.uuidString)"
    }

    /// Recovers the dragged workspace id from a legacy or tokenized payload.
    static func workspaceId(fromPasteboardString raw: String?) -> UUID? {
        SidebarWorkspaceDragPayloadParser().workspaceId(from: raw)
    }

    /// Reads the string representation AppKit exposes for this drag item.
    static func pasteboardString(from pasteboard: NSPasteboard) -> String? {
        let type = NSPasteboard.PasteboardType(Self.typeIdentifier)
        return pasteboard.string(forType: type)
            ?? pasteboard.data(forType: type).flatMap {
                String(data: $0, encoding: .utf8)
            }
    }

    /// Recovers the native session token from a tokenized payload.
    static func sessionId(fromPasteboardString raw: String?) -> UUID? {
        SidebarWorkspaceDragPayloadParser().sessionId(from: raw)
    }

    /// Reads the native session token from an AppKit drag pasteboard.
    static func sessionId(from pasteboard: NSPasteboard) -> UUID? {
        sessionId(fromPasteboardString: pasteboardString(from: pasteboard))
    }

    /// Reports whether the pasteboard carries the currently live native
    /// sidebar session. A residual or legacy payload is never considered live.
    static func hasLiveSession(
        in pasteboard: NSPasteboard,
        currentSessionId: UUID?
    ) -> Bool {
        guard let currentSessionId,
              let payloadSessionId = sessionId(from: pasteboard) else {
            return false
        }
        return payloadSessionId == currentSessionId
    }

    /// Creates an AppKit pasteboard item, optionally fenced to one session.
    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(
            pasteboardValue,
            forType: NSPasteboard.PasteboardType(Self.typeIdentifier)
        )
        return item
    }

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(pasteboardValue.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: Self.typeIdentifier, visibility: .ownProcess) { completion in
            // Data is already materialized, so a synchronous pasteboard request
            // never waits on work scheduled back to the main actor.
            completion(data, nil)
            return nil
        }
        return provider
    }
}
