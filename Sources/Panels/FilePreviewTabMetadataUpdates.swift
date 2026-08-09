import Foundation

/// Publishes bounded file-preview tab metadata to the panel's current owner.
@MainActor
final class FilePreviewTabMetadataUpdates {
    struct Update: Equatable, Sendable {
        let title: String
        let displayIcon: String?
        let isDirty: Bool
    }

    private var continuation: AsyncStream<Update>.Continuation?

    func makeStream(current: Update) -> AsyncStream<Update> {
        continuation?.finish()
        let (updates, continuation) = AsyncStream<Update>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = continuation
        _ = continuation.yield(current)
        return updates
    }

    func publish(_ update: Update) {
        _ = continuation?.yield(update)
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}

extension FilePreviewPanel {
    /// Creates the single owner-facing metadata stream, replacing an older observer.
    func makeTabMetadataUpdates() -> AsyncStream<FilePreviewTabMetadataUpdates.Update> {
        tabMetadataUpdates.makeStream(current: currentTabMetadataUpdate)
    }

    func publishTabMetadataUpdate() {
        tabMetadataUpdates.publish(currentTabMetadataUpdate)
    }

    private var currentTabMetadataUpdate: FilePreviewTabMetadataUpdates.Update {
        FilePreviewTabMetadataUpdates.Update(
            title: displayTitle,
            displayIcon: displayIcon,
            isDirty: isDirty
        )
    }
}
