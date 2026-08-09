import Foundation

/// The tab-facing state emitted by a file-preview panel.
nonisolated struct FilePreviewTabMetadata: Equatable, Sendable {
    /// The resolved tab title.
    let title: String
    /// The optional system-symbol name shown in the tab.
    let displayIcon: String?
    /// Whether the preview has unsaved edits.
    let isDirty: Bool
}

extension FilePreviewPanel {
    /// Creates a latest-value stream owned and emitted by this panel.
    func makeTabMetadataUpdates() -> AsyncStream<FilePreviewTabMetadata> {
        let observationID = UUID()
        let (stream, continuation) = AsyncStream<FilePreviewTabMetadata>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        tabMetadataContinuations[observationID] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tabMetadataContinuations.removeValue(forKey: observationID)
            }
        }
        continuation.yield(currentTabMetadata)
        return stream
    }

    /// Emits the consolidated tab snapshot after panel-owned metadata changes.
    func publishTabMetadataUpdate() {
        let metadata = currentTabMetadata
        for continuation in tabMetadataContinuations.values {
            continuation.yield(metadata)
        }
    }

    /// Finishes every tab metadata stream when the panel closes.
    func finishTabMetadataUpdates() {
        let continuations = Array(tabMetadataContinuations.values)
        tabMetadataContinuations.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }

    /// Returns one consistent snapshot of the panel's tab-facing state.
    private var currentTabMetadata: FilePreviewTabMetadata {
        FilePreviewTabMetadata(
            title: displayTitle,
            displayIcon: displayIcon,
            isDirty: isDirty
        )
    }
}
