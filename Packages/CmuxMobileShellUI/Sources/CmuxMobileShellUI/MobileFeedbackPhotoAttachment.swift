#if os(iOS)
import CmuxMobileFeedback
import Foundation
import PhotosUI
import SwiftUI

extension MobileFeedbackPhotoAttachment {
    @MainActor
    static func make(
        from item: PhotosPickerItem,
        index: Int,
        maximumByteCount: Int
    ) async throws -> MobileFeedbackPhotoAttachment {
        guard let sourceFile = try await item.loadTransferable(type: MobileFeedbackPickedPhotoFile.self) else {
            throw MobileFeedbackSubmissionError.photoReadFailed
        }
        defer { sourceFile.removeTemporaryFile() }

        return try await MobileFeedbackPhotoProcessor().makeAttachment(
            fromFileAt: sourceFile.url,
            index: index,
            maximumByteCount: maximumByteCount
        )
    }
}
#endif
