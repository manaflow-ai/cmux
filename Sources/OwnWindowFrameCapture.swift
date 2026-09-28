import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// One captured frame of one of cmux's own windows.
///
/// Unchecked because it carries a `CGImage`, which the capture does not keep
/// or mutate after handing it over.
struct OwnWindowFrame: @unchecked Sendable {
    let image: CGImage
    /// Pixels per point of the captured image, so a rectangle given in window
    /// points lands on the right pixels on a Retina display.
    let pointPixelScale: Double
}

/// Captures a single frame of a cmux window, with no Screen Recording permission.
///
/// Shared by the recorder, which samples it on a schedule, and
/// `window.screenshot`, which takes one frame and writes it. The current-process
/// query is what makes the permission unnecessary, and it is also what makes
/// this safe to ship in Release: it cannot reach another application's windows
/// even on a Mac where cmux was granted Screen Recording.
struct OwnWindowFrameCapture {
    enum Failure: Error, Equatable {
        case unsupportedSystem
        case windowGone
        case timedOut
        case captureFailed(String)
    }

    /// Shorter than the socket command's 20-second deadline so both the
    /// content lookup and the first frame have their own chance to fail and
    /// retire before the socket worker gives up.
    static let operationTimeoutNanoseconds: UInt64 = 8_000_000_000

    let windowID: CGWindowID

    /// Finds the window and returns a filter for it.
    ///
    /// A recording resolves this once and reuses it for every frame; a still
    /// resolves it and throws it away.
    func resolveFilter() async throws -> SCContentFilter {
        if #available(macOS 14.4, *) {
            // The current-process query captures cmux's own windows without
            // Screen Recording permission, and cannot reach another app's
            // windows even if that permission was granted.
            let content: SCShareableContent
            do {
                content = try await Self.withDeadline {
                    try await SCShareableContent.currentProcess
                }
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.captureFailed(error.localizedDescription)
            }
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw Failure.windowGone
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
        throw Failure.unsupportedSystem
    }

    /// Captures the window the filter names at its full pixel size.
    ///
    /// Cropping and scaling happen afterwards, from
    /// `WindowRecordingFrameGeometry`, so a still and a clip of the same region
    /// come out of the same pixels.
    static func sample(filter: SCContentFilter) async throws -> OwnWindowFrame {
        let info = SCShareableContent.info(for: filter)
        // A window that has closed reports an empty rectangle rather than an
        // error, and capturing that gives a one-pixel image.
        guard info.contentRect.width > 1, info.contentRect.height > 1 else {
            throw Failure.windowGone
        }
        let pixelScale = Double(info.pointPixelScale) > 0 ? Double(info.pointPixelScale) : 1
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((Double(info.contentRect.width) * pixelScale).rounded(.up)))
        configuration.height = max(1, Int((Double(info.contentRect.height) * pixelScale).rounded(.up)))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        do {
            let image = try await withDeadline {
                try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
            }
            return OwnWindowFrame(image: image, pointPixelScale: pixelScale)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.captureFailed(error.localizedDescription)
        }
    }

    /// Resolves the window and captures one frame, for a caller that captures
    /// once and does not keep a filter around.
    func captureOnce() async throws -> OwnWindowFrame {
        let filter = try await resolveFilter()
        return try await Self.sample(filter: filter)
    }

    /// Gives one ScreenCaptureKit operation its own deadline. A task-group
    /// scope does not return until all children have finished, so cancelling
    /// the losing child also retires it before the caller can start another
    /// capture or report completion.
    static func withDeadline<T: Sendable>(
        timeoutNanoseconds: UInt64 = operationTimeoutNanoseconds,
        operation: @escaping @Sendable () async throws -> T,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try Task.checkCancellation()
                return try await operation()
            }
            group.addTask {
                try await sleep(timeoutNanoseconds)
                try Task.checkCancellation()
                throw Failure.timedOut
            }

            let winner: Result<T, Error>
            do {
                guard let result = try await group.next() else {
                    throw Failure.timedOut
                }
                winner = .success(result)
            } catch {
                winner = .failure(error)
            }
            group.cancelAll()
            // Drain the cancelled loser explicitly. This is what makes a
            // timeout/cancellation a retirement boundary rather than merely a
            // promise to ignore a ScreenCaptureKit result that arrives later.
            while !group.isEmpty {
                _ = try? await group.next()
            }
            return try winner.get()
        }
    }
}
