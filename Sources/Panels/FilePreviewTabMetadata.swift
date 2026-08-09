import Combine

struct FilePreviewTabMetadata: Equatable, Sendable {
    let title: String
    let displayIcon: String?
    let isDirty: Bool
}

extension FilePreviewPanel {
    /// Exposes the existing published metadata as an owner-cancellable sequence.
    var tabMetadataUpdates: some AsyncSequence<FilePreviewTabMetadata, Never> {
        Publishers.CombineLatest3(
            $displayTitle.removeDuplicates(),
            $displayIcon.removeDuplicates(),
            $isDirty.removeDuplicates()
        )
        .map { title, displayIcon, isDirty in
            FilePreviewTabMetadata(
                title: title,
                displayIcon: displayIcon,
                isDirty: isDirty
            )
        }
        .values
    }
}
