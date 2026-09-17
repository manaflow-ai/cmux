#if canImport(UIKit)
import IOSurface

/// Retains one IOSurface while its immutable pixel copy runs on the serial
/// surface queue. Rendering is suppressed before this value is created, so the
/// underlying allocation cannot be reused until the copy completes.
nonisolated struct VerifiedReplaySurfaceCapture: @unchecked Sendable {
    let surface: IOSurface
}
#endif
