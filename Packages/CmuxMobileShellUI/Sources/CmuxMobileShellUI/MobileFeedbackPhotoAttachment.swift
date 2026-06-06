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
        guard let sourceData = try await item.loadTransferable(type: Data.self),
              sourceData.isEmpty == false else {
            throw MobileFeedbackSubmissionError.photoReadFailed
        }

        return try await MobileFeedbackPhotoProcessor.makeAttachment(
            from: sourceData,
            index: index,
            maximumByteCount: maximumByteCount
        )
    }
}
#endif
