import AppKit
import UniformTypeIdentifiers

/// Drag payload used when reordering workspace group sections in the sidebar.
enum SidebarWorkspaceGroupDragPayload {
    static let typeIdentifier = "com.cmux.sidebar-group-reorder"
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]
    private static let prefix = "cmux.sidebar-group."

    static func provider(for groupId: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = "\(prefix)\(groupId.uuidString)"
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            let data = payload.data(using: .utf8)
            Task { @MainActor in
                completion(data, nil)
            }
            return nil
        }
        return provider
    }

    static func loadGroupId(
        from providers: [NSItemProvider],
        completion: @escaping (UUID?) -> Void
    ) {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(typeIdentifier) }) else {
            completion(nil)
            return
        }
        _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            guard let data,
                  let raw = String(data: data, encoding: .utf8),
                  raw.hasPrefix(prefix),
                  let uuid = UUID(uuidString: String(raw.dropFirst(prefix.count))) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(uuid) }
        }
    }
}
