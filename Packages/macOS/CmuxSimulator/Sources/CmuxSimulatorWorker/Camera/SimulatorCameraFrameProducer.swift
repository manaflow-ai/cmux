@preconcurrency import AVFoundation
import CmuxSimulator
import CoreImage
import Foundation

protocol SimulatorCameraTiming: Sendable {
    func now() -> Duration
    func sleep(for duration: Duration) async throws
    func sleep(until deadline: Duration, tolerance: Duration) async throws
}

private struct ContinuousSimulatorCameraTiming: SimulatorCameraTiming {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    init() {
        origin = clock.now
    }

    func now() -> Duration {
        origin.duration(to: clock.now)
    }

    func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }

    func sleep(until deadline: Duration, tolerance: Duration) async throws {
        try await clock.sleep(until: origin.advanced(by: deadline), tolerance: tolerance)
    }
}

@MainActor
final class SimulatorCameraFrameProducer {
    private let surfaceRing: SimulatorCameraSurfaceRing
    private let timing: any SimulatorCameraTiming
    private let sessionRunner: SimulatorCameraSessionRunner
    private var videoTask: Task<Void, Never>?
    private var captureSession: SimulatorCameraCaptureSessionBox?
    private var captureDelegate: SimulatorCameraCaptureDelegate?

    init(
        surfaceRing: SimulatorCameraSurfaceRing,
        timing: any SimulatorCameraTiming = ContinuousSimulatorCameraTiming(),
        sessionRunner: SimulatorCameraSessionRunner = SimulatorCameraSessionRunner()
    ) {
        self.surfaceRing = surfaceRing
        self.timing = timing
        self.sessionRunner = sessionRunner
    }

    deinit {
        videoTask?.cancel()
        if let captureSession { sessionRunner.stopDetached(captureSession) }
    }

    func configure(_ configuration: SimulatorCameraConfiguration) async throws {
        let source = Self.unwrappedSource(configuration)

        await stop()
        switch source {
        case .disabled:
            return
        case .placeholder:
            let surfaceRing = surfaceRing
            let timing = timing
            videoTask = Task(priority: .userInitiated) {
                await Self.playPlaceholder(surfaceRing: surfaceRing, timing: timing)
            }
        case let .image(url):
            guard url.isFileURL,
                  FileManager.default.isReadableFile(atPath: url.path),
                  let image = CIImage(contentsOf: url)
            else {
                throw SimulatorWorkerFailure.privateAPIUnavailable(
                    "The synthetic-camera image is missing or unreadable."
                )
            }
            // Match serve-sim camera semantics: preserve the entire source and
            // letterbox aspect-ratio differences instead of cropping them.
            surfaceRing.publish(image, fillsFrame: false)
        case let .video(url, loops):
            guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
                throw SimulatorWorkerFailure.privateAPIUnavailable(
                    "The synthetic-camera video is missing or unreadable."
                )
            }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else {
                throw SimulatorWorkerFailure.privateAPIUnavailable(
                    "The synthetic-camera video has no video track."
                )
            }
            let surfaceRing = surfaceRing
            let timing = timing
            videoTask = Task(priority: .userInitiated) {
                await Self.playVideo(
                    url: url,
                    loops: loops,
                    surfaceRing: surfaceRing,
                    timing: timing
                )
            }
        case let .hostCamera(deviceIdentifier):
            try await startHostCamera(deviceIdentifier: deviceIdentifier)
        case .targeted:
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "The synthetic-camera target configuration could not be resolved."
            )
        }
    }

    func stop() async {
        videoTask?.cancel()
        videoTask = nil
        if let captureSession {
            await sessionRunner.stop(captureSession)
        }
        captureSession = nil
        captureDelegate = nil
    }

    @concurrent private static func playPlaceholder(
        surfaceRing: SimulatorCameraSurfaceRing,
        timing: any SimulatorCameraTiming
    ) async {
        var frame: UInt64 = 0
        while !Task.isCancelled {
            let phase = Double(frame % 180) / 180 * .pi * 2
            let left = CIImage(
                color: CIColor(
                    red: 0.20 + 0.12 * sin(phase),
                    green: 0.30 + 0.10 * sin(phase + 2),
                    blue: 0.58 + 0.12 * sin(phase + 4)
                )
            ).cropped(
                to: CGRect(
                    x: 0,
                    y: 0,
                    width: SimulatorCameraSurfaceRing.width / 2,
                    height: SimulatorCameraSurfaceRing.height
                )
            )
            let right = CIImage(
                color: CIColor(
                    red: 0.58 + 0.12 * sin(phase + 3),
                    green: 0.22 + 0.10 * sin(phase + 5),
                    blue: 0.38 + 0.12 * sin(phase + 1)
                )
            ).cropped(
                to: CGRect(
                    x: SimulatorCameraSurfaceRing.width / 2,
                    y: 0,
                    width: SimulatorCameraSurfaceRing.width / 2,
                    height: SimulatorCameraSurfaceRing.height
                )
            )
            surfaceRing.publish(left.composited(over: right), fillsFrame: true)
            frame &+= 1
            do {
                // This cancellable delay is the synthetic camera frame cadence.
                try await timing.sleep(for: .milliseconds(33))
            } catch {
                return
            }
        }
    }

    @concurrent private static func playVideo(
        url: URL,
        loops: Bool,
        surfaceRing: SimulatorCameraSurfaceRing,
        timing: any SimulatorCameraTiming
    ) async {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first else { return }
        repeat {
            guard !Task.isCancelled,
                  let (reader, output) = try? makeReader(asset: asset, track: track)
            else {
                return
            }
            let playbackStart = timing.now()
            var firstPresentationTime: Double?
            while !Task.isCancelled, let sampleBuffer = output.copyNextSampleBuffer() {
                let presentationTime = CMTimeGetSeconds(
                    CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                )
                if presentationTime.isFinite {
                    if firstPresentationTime == nil {
                        firstPresentationTime = presentationTime
                    }
                    let elapsed = max(0, presentationTime - (firstPresentationTime ?? presentationTime))
                    do {
                        // This cancellable deadline preserves source presentation timing.
                        try await timing.sleep(
                            until: playbackStart + .milliseconds(
                                Int64((elapsed * 1_000).rounded())
                            ),
                            tolerance: .milliseconds(2)
                        )
                    } catch {
                        reader.cancelReading()
                        return
                    }
                }
                if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    surfaceRing.publish(pixelBuffer: pixelBuffer, fillsFrame: false)
                }
            }
            let completed = reader.status == .completed
            reader.cancelReading()
            if !completed { return }
        } while loops && !Task.isCancelled
    }

    nonisolated private static func makeReader(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "AVFoundation rejected BGRA output for the synthetic-camera video."
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                reader.error?.localizedDescription ?? "The synthetic-camera video could not start."
            )
        }
        return (reader, output)
    }

    private func startHostCamera(deviceIdentifier: String?) async throws {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            authorized = false
        @unknown default:
            authorized = false
        }
        guard authorized else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Camera access is required to mirror a host camera into Simulator."
            )
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        let device: AVCaptureDevice?
        if let deviceIdentifier {
            device = discovery.devices.first { $0.uniqueID == deviceIdentifier }
        } else {
            device = discovery.devices.first
        }
        guard let device else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "The requested host camera is not available."
            )
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "AVFoundation rejected the selected host camera input."
            )
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "AVFoundation rejected host-camera frame output."
            )
        }
        session.addOutput(output)
        session.commitConfiguration()

        let delegate = SimulatorCameraCaptureDelegate(surfaceRing: surfaceRing)
        output.setSampleBufferDelegate(
            delegate,
            queue: DispatchQueue(label: "com.cmux.simulator.camera.capture", qos: .userInteractive)
        )
        captureDelegate = delegate
        let sessionBox = SimulatorCameraCaptureSessionBox(session)
        captureSession = sessionBox
        await sessionRunner.start(sessionBox)
        do {
            try Task.checkCancellation()
        } catch {
            await sessionRunner.stop(sessionBox)
            captureSession = nil
            captureDelegate = nil
            throw error
        }
    }

    static func availableHostCameras() -> [SimulatorHostCameraDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.map {
            SimulatorHostCameraDevice(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    private static func unwrappedSource(
        _ configuration: SimulatorCameraConfiguration
    ) -> SimulatorCameraConfiguration {
        if case let .targeted(_, source) = configuration {
            return unwrappedSource(source)
        }
        return configuration
    }
}
