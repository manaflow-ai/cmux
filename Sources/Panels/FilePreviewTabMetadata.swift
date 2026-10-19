import Foundation

/// The tab-facing state emitted by a file-preview panel.
struct FilePreviewTabMetadata: Equatable, Sendable {
    /// The resolved tab title.
    let title: String
    /// The optional system-symbol name shown in the tab.
    let displayIcon: String?
    /// Whether the preview has unsaved edits.
    let isDirty: Bool
}

extension FilePreviewPanel {
    /// Replaces the current container binding and immediately projects current state.
    func bindTabMetadata(to host: any FilePreviewTabMetadataHost) {
        tabMetadataHost = host
        host.applyFilePreviewTabMetadata(currentTabMetadata, panelId: id)
    }

    /// Clears the current container binding during transfer or teardown.
    func unbindTabMetadata() {
        tabMetadataHost = nil
    }

    /// Projects the consolidated snapshot through the panel's single active host.
    func publishTabMetadataUpdate() {
        tabMetadataHost?.applyFilePreviewTabMetadata(
            currentTabMetadata,
            panelId: id
        )
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
