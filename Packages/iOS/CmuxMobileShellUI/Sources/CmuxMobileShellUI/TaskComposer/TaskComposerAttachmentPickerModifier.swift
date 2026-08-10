#if os(iOS)
import PhotosUI
import CmuxAgentChatUI
import SwiftUI
import UniformTypeIdentifiers

/// Hosts the system photo and file pickers shared by both composer layouts.
struct TaskComposerAttachmentPickerModifier: ViewModifier {
    @Binding var isPhotoPickerPresented: Bool
    @Binding var photoSelection: [PhotosPickerItem]
    @Binding var isFileImporterPresented: Bool
    let remainingCount: Int
    let selectedPhotos: ([PhotosPickerItem]) -> Void
    let selectedFiles: (Result<[URL], any Error>) -> Void

    func body(content: Content) -> some View {
        content.modifier(MobileAttachmentPickerModifier(
            isPhotoPickerPresented: $isPhotoPickerPresented,
            photoSelection: $photoSelection,
            isFileImporterPresented: $isFileImporterPresented,
            remainingCount: remainingCount,
            selectedPhotos: selectedPhotos,
            selectedFiles: selectedFiles
        ))
    }
}
#endif
