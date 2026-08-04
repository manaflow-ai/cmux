import CoreGraphics
import Foundation

struct ApplicationCaptureTarget: Equatable {
    let windowID: CGWindowID
    let processID: pid_t
}
