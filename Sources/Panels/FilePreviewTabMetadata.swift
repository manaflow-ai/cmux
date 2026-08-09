import Combine

struct FilePreviewTabMetadata: Equatable {
    let title: String
    let displayIcon: String?
    let isDirty: Bool
}

extension FilePreviewPanel {
    /// Reuses the panel's existing observation path for every tab owner.
    var tabMetadataPublisher: AnyPublisher<FilePreviewTabMetadata, Never> {
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
        .eraseToAnyPublisher()
    }
}
