import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SimulatorPreviewFrameStore {
    var image: NSImage?
    var imageSize: CGSize = .zero

    func update(image: NSImage, imageSize: CGSize) {
        self.image = image
        self.imageSize = imageSize
    }

    func clear() {
        image = nil
        imageSize = .zero
    }
}
