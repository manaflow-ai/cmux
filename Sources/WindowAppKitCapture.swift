#if DEBUG
import Foundation

/// Holds an AppKit-rendered PNG and whether every external child layer was composited.
struct WindowAppKitCapture: Sendable {
    let pngData: Data
    let capturedAllExternalContent: Bool
}
#endif
