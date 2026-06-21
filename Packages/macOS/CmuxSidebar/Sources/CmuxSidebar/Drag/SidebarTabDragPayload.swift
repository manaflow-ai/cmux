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
/// lint:allow namespace-type — frozen UTType-constants + item-provider-factory
/// holder for the sidebar reorder drag contract; there is no value type to host
/// these and the static spelling is part of the frozen wire/call contract.
public enum SidebarTabDragPayload {
    /// The exported uniform type identifier for the sidebar reorder drag.
    public static let typeIdentifier = "com.cmux.sidebar-tab-reorder"
    /// The exported drop content `UTType`.
    public static let dropContentType = UTType(exportedAs: typeIdentifier)
    /// The drop content types accepted by sidebar reorder drop targets.
    public static let dropContentTypes: [UTType] = [dropContentType]
    /// The string prefix on the encoded drag payload.
    public static let prefix = "cmux.sidebar-tab."

    /// Builds the `NSItemProvider` carrying the dragged workspace's id.
    public static func provider(for tabId: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = "\(prefix)\(tabId.uuidString)"
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            let data = payload.data(using: .utf8)
            Task { @MainActor in
                completion(data, nil)
            }
            return nil
        }
        return provider
    }
}
