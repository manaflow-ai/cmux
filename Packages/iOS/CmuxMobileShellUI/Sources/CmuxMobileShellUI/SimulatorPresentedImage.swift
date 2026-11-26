#if canImport(UIKit)
import CMUXMobileCore
import Foundation
@preconcurrency import UIKit

/// A fully decoded image safe to transfer back to the main-actor presenter.
struct SimulatorPresentedImage: @unchecked Sendable {
    // UIImage is immutable after construction here and is only consumed by
    // SwiftUI on the main actor, so crossing the decode task is safe.
    let image: UIImage

    static func decode(_ frame: MobileSimulatorFrameEvent) async -> SimulatorPresentedImage? {
        let base64 = frame.dataBase64
        let task = Task<SimulatorPresentedImage?, Never>.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let data = Data(base64Encoded: base64),
                  let image = UIImage(data: data),
                  let prepared = image.preparingForDisplay() else { return nil }
            guard !Task.isCancelled else { return nil }
            return SimulatorPresentedImage(image: prepared)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
#endif
