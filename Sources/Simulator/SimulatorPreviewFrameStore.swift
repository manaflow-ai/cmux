import AppKit
import SwiftUI

@MainActor
final class SimulatorPreviewFrameStore: ObservableObject {
    @Published var image: NSImage?
    @Published var imageSize: CGSize = .zero

    func update(image: NSImage, imageSize: CGSize) {
        self.image = image
        self.imageSize = imageSize
    }

    func clear() {
        image = nil
        imageSize = .zero
    }
}
