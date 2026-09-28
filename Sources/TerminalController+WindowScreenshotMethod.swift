import AppKit
import CmuxFoundation
import CoreGraphics
import Foundation

extension TerminalController {
    /// Socket-worker handler for `window.screenshot`.
    ///
    /// A still of one of cmux's own windows, on the capture path recording
    /// already uses, so it needs no Screen Recording permission and ships in
    /// Release. The DEBUG `screenshot` command is a different thing: it can
    /// composite overlays and pick backends, and it is missing from every build
    /// we dogfood, which is where an agent actually runs.
    ///
    /// Blocks its worker thread while ScreenCaptureKit answers, so the execution
    /// policy keeps it off the main actor.
    nonisolated func v2WindowScreenshotOnSocketWorker(params: [String: Any]) -> V2CallResult {
        let request: WindowScreenshotRequest
        do {
            request = try WindowScreenshotRequest.make(params: params)
        } catch let failure as WindowScreenshotRequest.Failure {
            return .err(code: "invalid_params", message: failure.message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: error.localizedDescription, data: nil)
        }
        guard let windowID = captureWindowID(handle: request.windowHandle) else {
            return .err(
                code: "not_found",
                message: request.windowHandle.map { "Window \($0) is not available" }
                    ?? "No window available",
                data: nil
            )
        }

        let outcome: Result<WindowStillImageWriter.Written, Error>? = socketAwaitCallback(
            timeout: 20
        ) { completion in
            Task {
                do {
                    completion(.success(try await Self.captureStill(
                        request: request,
                        windowID: windowID
                    )))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        guard let outcome else {
            return .err(
                code: "timeout",
                message: "window.screenshot timed out after 20 seconds",
                data: nil
            )
        }
        switch outcome {
        case let .success(written):
            var payload: [String: Any] = [
                "path": written.url.path,
                "width": written.width,
                "height": written.height,
                "bytes": written.byteCount,
                "format": request.format.rawValue,
            ]
            if !request.label.isEmpty {
                payload["label"] = request.label
            }
            if let handle = request.windowHandle {
                payload["window"] = handle
            }
            return .ok(payload)
        case let .failure(error):
            return .err(
                code: Self.screenshotErrorCode(for: error),
                message: error.localizedDescription,
                data: nil
            )
        }
    }

    /// Captures one frame, crops and scales it, and writes the file.
    private nonisolated static func captureStill(
        request: WindowScreenshotRequest,
        windowID: CGWindowID
    ) async throws -> WindowStillImageWriter.Written {
        let frame = try await OwnWindowFrameCapture(windowID: windowID).captureOnce()
        let geometry = try WindowRecordingFrameGeometry.plan(
            windowPixelWidth: frame.image.width,
            windowPixelHeight: frame.image.height,
            pointPixelScale: frame.pointPixelScale,
            region: {
                if case let .region(region) = request.target { return region }
                return nil
            }(),
            scale: request.scale,
            maximumWidth: request.maximumWidth,
            // A still has no encoder demanding even dimensions, so the caller
            // gets the pixels they asked for.
            widthQuantum: 1
        )
        let image: CGImage
        if geometry.cropsNothing, geometry.scalesNothing, request.caption == nil {
            // Nothing to crop, scale or draw: re-rendering would only cost a
            // copy and the window's color space.
            image = frame.image
        } else {
            guard let composed = WindowRecordingFrameComposer.compose(
                source: frame.image,
                geometry: geometry,
                caption: request.caption
            ) else {
                throw WindowStillImageWriter.Failure.encodeFailed("the frame could not be composed")
            }
            image = composed
        }
        return try WindowStillImageWriter.write(
            image,
            to: Self.screenshotOutputURL(request: request),
            format: request.format,
            quality: request.quality
        )
    }

    private nonisolated static func screenshotOutputURL(
        request: WindowScreenshotRequest
    ) -> URL {
        if let outputPath = request.outputPath {
            return URL(fileURLWithPath: outputPath)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(WindowRecordingOutputNaming.screenshotDirectoryName)
            .appendingPathComponent(WindowRecordingOutputNaming.filename(
                label: request.label,
                identifier: WindowRecordingOutputNaming.identifier(date: Date()),
                fileExtension: request.format.preferredFileExtension
            ))
    }

    /// Maps a screenshot error onto the socket error code the caller sees.
    ///
    /// Internal rather than private so a test can pin every case, for the same
    /// reason as the recorder's: a CLI and a tour branch on these.
    nonisolated static func screenshotErrorCode(for error: Error) -> String {
        if let failure = error as? OwnWindowFrameCapture.Failure {
            switch failure {
            case .unsupportedSystem:
                return "unsupported"
            case .windowGone:
                return "not_found"
            case .captureFailed:
                return "internal_error"
            }
        }
        if let failure = error as? WindowStillImageWriter.Failure {
            switch failure {
            case .outputNotAFile:
                // The caller's `out` names something that is not a file a
                // screenshot may replace, so this is their parameter.
                return "invalid_params"
            case .encodeFailed:
                return "internal_error"
            }
        }
        if error is WindowRecordingFrameGeometry.Failure {
            return "invalid_params"
        }
        return "internal_error"
    }
}
