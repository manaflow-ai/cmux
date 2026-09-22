#if os(iOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Hosts the system photo and file pickers shared by both composer layouts.
struct TaskComposerAttachmentPickerModifier: ViewModifier {
    @Binding var isPhotoPickerPresented: Bool
    @Binding var photoSelection: [PhotosPickerItem]
    @Binding var isFileImporterPresented: Bool
    let remainingCount: Int
    let selectedPhotos: ([PhotosPickerItem]) -> Void
    let dismissedPhotos: () -> Void
    let selectedFiles: (Result<[URL], any Error>) -> Void

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $photoSelection,
                maxSelectionCount: max(remainingCount, 1),
                // Explicitly include videos as well as images. Some iOS
                // versions open an unset filter in the image collection,
                // hiding videos even though the transfer type accepts them.
                matching: .any(of: [.images, .videos])
            )
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onCompletion: selectedFiles
            )
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                selectedPhotos(items)
            }
            .onChange(of: isPhotoPickerPresented) { wasPresented, isPresented in
                guard wasPresented, !isPresented else { return }
                dismissedPhotos()
            }
    }
}
#endif
