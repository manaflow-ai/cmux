public import Foundation

/// Reconciles a resolved collaboration document with the peer's local file.
public struct DiskReconciler: Sendable {
    private let store: any CollaborationFileStoring
    private let hash: TextHash

    /// Creates a disk reconciler.
    /// - Parameters:
    ///   - store: File storage operations to use.
    ///   - hash: Stable text hash implementation.
    init(store: any CollaborationFileStoring, hash: TextHash = TextHash()) {
        self.store = store
        self.hash = hash
    }

    /// Writes collaboration text to disk or a conflict sibling.
    /// - Parameters:
    ///   - text: The resolved collaboration text.
    ///   - fileURL: The original file URL.
    ///   - baselineHash: The hash recorded when collaboration opened.
    ///   - lastWrittenHash: The hash from the previous collaboration write.
    /// - Returns: The reconciliation result.
    public func reconcile(
        text: String,
        fileURL: URL,
        baselineHash: String,
        lastWrittenHash: String?
    ) async throws -> DiskReconciliationResult {
        let currentText = try await store.readText(at: fileURL)
        let currentHash = hash.hash(currentText)
        let collaborationHash = hash.hash(text)
        if currentHash == baselineHash || currentHash == lastWrittenHash {
            try await store.writeText(text, to: fileURL)
            return .wroteOriginal(fileURL: fileURL, textHash: collaborationHash)
        }

        let conflictURL = conflictURL(for: fileURL)
        try await store.writeText(text, to: conflictURL)
        return .wroteConflict(
            originalURL: fileURL,
            conflictURL: conflictURL,
            originalHash: currentHash,
            collaborationHash: collaborationHash
        )
    }

    private func conflictURL(for fileURL: URL) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let base = fileURL.deletingPathExtension()
        let ext = fileURL.pathExtension
        let name = "\(base.lastPathComponent).cmux-collab-conflict-\(stamp)"
        let finalName = ext.isEmpty ? name : "\(name).\(ext)"
        return base.deletingLastPathComponent().appendingPathComponent(finalName)
    }
}
