import AppKit

extension SidebarTabDragPayload {
    /// Decodes a workspace drag payload for group-header drop targets.
    static func loadTabId(
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
