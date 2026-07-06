public import Foundation
public import UniformTypeIdentifiers

/// The drag-and-drop payload that identifies a workspace being reordered within
/// (or moved across) a cmux sidebar.
///
/// The payload is a single `NSItemProvider` carrying the dragged workspace's id
/// under the private exported type `com.cmux.sidebar-tab-reorder`. The actual
/// drag identity that drop delegates key on is resolved from the in-process
/// ``SidebarWorkspaceDragRegistering`` registry (the item-provider data is
/// delivered asynchronously and cannot be read synchronously inside a drop
/// delegate); this provider exists so SwiftUI's drag machinery has a payload to
/// carry and so the destination's `onDrop(of:)` content-type filter matches.
///
/// The type identifier and item-provider encoding are part of the on-the-wire
/// drag contract (the exported UTType is declared in the app's
/// `UTExportedTypeDeclarations`); they are frozen and must not change.
///
public struct SidebarTabDragPayload {
    /// The exported uniform type identifier for the sidebar reorder drag.
    public static let typeIdentifier = "com.cmux.sidebar-tab-reorder"
    /// The exported drop content `UTType`.
    public static let dropContentType = UTType(exportedAs: typeIdentifier)
    /// The drop content types accepted by sidebar reorder drop targets.
    public static let dropContentTypes: [UTType] = [dropContentType]
    /// The string prefix on the encoded drag payload.
    public static let prefix = "cmux.sidebar-tab."

    /// The dragged workspace's id.
    public let tabId: UUID

    /// Creates a payload for the dragged workspace.
    public init(tabId: UUID) {
        self.tabId = tabId
    }

    /// Builds the `NSItemProvider` carrying the dragged workspace's id.
    ///
    /// The payload data is materialized eagerly and the registration completes
    /// synchronously: a synchronous pasteboard request must never wait on work
    /// scheduled back to the main actor (issue #7344's drag deadlock).
    public func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = "\(Self.prefix)\(tabId.uuidString)"
        let data = Data(payload.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: Self.typeIdentifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}
