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

    /// The requested processes that still run but are not among the capture's applications.
    static func missing(_ requested: [pid_t], in content: SCShareableContent) -> [pid_t] {
        let seen = Set(content.applications.map(\.processID))
        return requested.filter { pid in
            !seen.contains(pid) && (kill(pid, 0) == 0 || errno == EPERM)
        }
    }

    /// Every app the capture sees (any window, any level), as the engine's `capture_apps` JSON.
    func applications() -> Result<Data, Failure> {
        guard CGPreflightScreenCaptureAccess() else { return .failure(.permission) }
        let box = OSAllocatedUnfairLock<Result<Data, Failure>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        // task-owner: one listing; the calling engine thread waits for it below, bounded by `deadline`.
        Task.detached(priority: .userInitiated) {
            let result: Result<Data, Failure>
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let rows: [[String: Any]] = content.applications.map {
                    ["pid": Int($0.processID), "id": $0.bundleIdentifier, "name": $0.applicationName]
                }
                result = .success((try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8))
            } catch {
                result = .failure(.failed(String(describing: error)))
            }
            box.withLock { $0 = result }
            done.signal()
        }
        // concurrency-allow: the engine's capture_apps callback is synchronous by contract and runs on an engine thread, never main.
        guard done.wait(timeout: .now() + Self.deadline) == .success, let result = box.withLock({ $0 }) else {
            return .failure(.timedOut)
        }
        return result
    }

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

    /// How long a window capture may reuse ScreenCaptureKit's window list (reading it costs tens of
    /// milliseconds per screenshot). A window missing from it, or a capture that fails with it,
    /// reads it again. Display captures always read it fresh: their exclusions need every app.
    static let contentReuse: Duration = .seconds(1)

    /// One read of the shareable content and when it was taken.
    struct CachedContent: @unchecked Sendable {
        // concurrency-allow: SCShareableContent is an immutable snapshot that ScreenCaptureKit hands out to any task; it is only read after it is stored here.
        let content: SCShareableContent
        let at: ContinuousClock.Instant
    }

    static let cachedContent = OSAllocatedUnfairLock<CachedContent?>(initialState: nil)

    static func freshContent() async throws -> SCShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        cachedContent.withLock { $0 = CachedContent(content: content, at: .now) }
        return content
    }

    /// Recent content that holds window `id` where it is now, if any. The window's frame decides
    /// how screenshot pixels map to the desktop, so content whose frame for it differs from the
    /// window server's current bounds (it moved or resized) is not reused.
    static func reusableContent(holding id: UInt32) -> SCShareableContent? {
        let content: SCShareableContent? = cachedContent.withLock { cached in
            guard let cached, ContinuousClock.now - cached.at < contentReuse else { return nil }
            return cached.content
        }
        guard let content, let window = content.windows.first(where: { $0.windowID == id }),
              let bounds = currentBounds(of: id), bounds == window.frame else { return nil }
        return content
    }

    /// The window server's bounds of window `id` now (global points, top-left origin).
    static func currentBounds(of id: UInt32) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let entry = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == id }),
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    static func still(_ target: CaptureTarget) async -> Result<CapturedFrame, Failure> {
        if case .window(let id) = target, let content = reusableContent(holding: id) {
            // A capture with the reused list that fails (the window closed or changed) tries once
            // more with a fresh list below.
            if case .success(let frame) = await still(target, content: content) { return .success(frame) }
        }
        do {
            // A window capture holds only its window's pixels, so it needs no wait for this
            // process's own windows. For a display capture they are left out: the overlay creates
            // them on the main queue in the order the engine asked (the cursor event comes before
            // its capture), so main is drained first and every window it already queued exists;
            // then all windows, not only on-screen ones, are read, so this process is in
            // `applications` once it has made any window, even one that shows only later.
            if case .display = target { await MainActor.run {} }
            return await still(target, content: try await freshContent())
        } catch let error as SCStreamError where error.code == .userDeclined {
            return .failure(.permission)
        } catch {
            return .failure(.failed(String(describing: error)))
        }
    }

    static func still(_ target: CaptureTarget, content initial: SCShareableContent) async -> Result<CapturedFrame, Failure> {
        do {
            var content = initial
            // Every requested app that still runs must be left out: the capture fails rather than
            // show one (the engine then paints denied windows out whole). One re-read first, for
            // an app that made its first window just now; an app that quit since is not missing.
            if case .display(_, let excluding) = target, !excluding.isEmpty {
                if !Self.missing(excluding, in: content).isEmpty {
                    content = try await freshContent()
                }
                let missing = Self.missing(excluding, in: content)
                if !missing.isEmpty {
                    return .failure(.failed("exclusion_incomplete: cannot leave out pid \(missing.map(String.init).joined(separator: ","))"))
                }
            }
            let own = content.applications.filter { $0.processID == getpid() }
            let filter: SCContentFilter
            let frame: CGRect
            switch target {
            case .window(let id):
                guard let window = content.windows.first(where: { $0.windowID == id }) else { return .failure(.noWindow(id)) }
                filter = SCContentFilter(desktopIndependentWindow: window)
                frame = window.frame
            case .display(let id, let excluding):
                let wanted = id ?? CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == wanted }) else { return .failure(.noDisplay(id)) }
                // This process's windows (the agent cursor, the approval panel) and every window of the
                // denied apps never reach an agent: the compositor leaves them out, at every window
                // level, and draws what is behind them (an allowed window keeps its pixels).
                let left = Set(excluding)
                let denied = content.applications.filter { left.contains($0.processID) }
                filter = SCContentFilter(display: display, excludingApplications: own + denied, exceptingWindows: [])
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
