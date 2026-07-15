import Foundation

/// Scale rules shared by artifact image zoom gestures and tests.
struct ChatArtifactZoomPolicy: Equatable, Sendable {
    let minimumScale: Double
    let doubleTapScale: Double
    let maximumScale: Double

    init(
        minimumScale: Double = 1,
        doubleTapScale: Double = 3,
        maximumScale: Double = 8
    ) {
        self.minimumScale = minimumScale
        self.doubleTapScale = doubleTapScale
        self.maximumScale = maximumScale
    }

    func isAtMinimum(_ scale: Double) -> Bool {
        abs(scale - minimumScale) <= 0.01
    }

    func scaleAfterDoubleTap(currentScale: Double) -> Double {
        isAtMinimum(currentScale) ? doubleTapScale : minimumScale
    }
}
