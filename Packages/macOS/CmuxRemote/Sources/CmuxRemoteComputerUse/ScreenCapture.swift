// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Darwin
import Foundation
import os
@preconcurrency import ScreenCaptureKit

/// One captured frame: tightly packed RGBA8, plus where it sits on the desktop.
struct CapturedFrame: Sendable {
    var width: Int
    var height: Int
    var rgba: Data
    /// Pixels per point.
    var scale: Double
    /// Top-left, global points.
    var origin: CGPoint
}

/// The engine's `capture` (cmux_computer_use.h): ScreenCaptureKit stills of one window or one
/// display, without the pointer and without this process's own windows (the agent cursor and
/// the approval panel), so an agent never sees its own cursor in a screenshot. Runs on the
/// engine's calling thread, which may block (never the main thread).
struct ScreenCapture: Sendable {
    enum Failure: Error, CustomStringConvertible, Equatable {
        case permission
        case noWindow(UInt32)
        case noDisplay(UInt32?)
        case timedOut
        case failed(String)

        /// The engine maps a message containing "permission" to its permission-missing error.
        var description: String {
            switch self {
            case .permission: "Screen Recording permission is not granted to cmux Remote"
            case .noWindow(let id): "window \(id) is not on screen"
            case .noDisplay(let id): id.map { "display \($0) is not connected" } ?? "no display"
            case .timedOut: "the capture did not finish in time"
            case .failed(let message): message
            }
        }
    }

    /// The longest one capture may take.
    static let deadline: TimeInterval = 10

    /// One still of `target`; blocks the calling thread until ScreenCaptureKit answers.
    func capture(_ target: CaptureTarget) -> Result<CapturedFrame, Failure> {
        guard CGPreflightScreenCaptureAccess() else { return .failure(.permission) }
        let box = OSAllocatedUnfairLock<Result<CapturedFrame, Failure>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        // task-owner: one capture; the calling engine thread waits for it below, bounded by `deadline`.
        Task.detached(priority: .userInitiated) {
            let result = await Self.still(target)
            box.withLock { $0 = result }
            done.signal()
        }
        // concurrency-allow: the engine's capture callback is synchronous by contract and runs on an engine thread, never main.
        guard done.wait(timeout: .now() + Self.deadline) == .success, let result = box.withLock({ $0 }) else {
            return .failure(.timedOut)
        }
        return result
    }

    static func still(_ target: CaptureTarget) async -> Result<CapturedFrame, Failure> {
        do {
            // Agents never see this process's windows (the agent cursor, the approval panel). The
            // overlay creates them on the main queue in the order the engine asked (the cursor event
            // comes before its capture), so main is drained first and every window it already
            // queued exists; then all windows, not only on-screen ones, are read, so this process is
            // in `applications` once it has made any window, even one that shows only later.
            await MainActor.run {}
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let own = content.applications.filter { $0.processID == getpid() }
            let filter: SCContentFilter
            let frame: CGRect
            switch target {
            case .window(let id):
                guard let window = content.windows.first(where: { $0.windowID == id }) else { return .failure(.noWindow(id)) }
                filter = SCContentFilter(desktopIndependentWindow: window)
                frame = window.frame
            case .display(let id):
                let wanted = id ?? CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == wanted }) else { return .failure(.noDisplay(id)) }
                // This process's windows (the agent cursor, the approval panel) never reach an agent.
                filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                frame = display.frame
            }
            let scale = Double(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int((frame.width * scale).rounded()))
            configuration.height = max(1, Int((frame.height * scale).rounded()))
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let rgba = rgba(image) else { return .failure(.failed("could not read the captured image")) }
            return .success(CapturedFrame(width: image.width, height: image.height, rgba: rgba,
                                          scale: frame.width > 0 ? Double(image.width) / frame.width : scale,
                                          origin: frame.origin))
        } catch let error as SCStreamError where error.code == .userDeclined {
            return .failure(.permission)
        } catch {
            return .failure(.failed(String(describing: error)))
        }
    }

    /// Tightly packed RGBA8 (premultiplied, sRGB) of `image`.
    static func rgba(_ image: CGImage) -> Data? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = Data(count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }
}
