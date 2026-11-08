@preconcurrency import AVFoundation
import CmuxSimulator
import CoreImage
import Foundation

@MainActor
final class SimulatorCameraFrameProducer {
    private let surfaceRing: SimulatorCameraSurfaceRing
    private let timing: any SimulatorCameraTiming
    private let playback: SimulatorCameraPlayback
    private let sessionRunner: SimulatorCameraSessionRunner
    private let fileManager: FileManager
    private let captureQueue = DispatchQueue(
        label: "com.cmux.simulator.camera.capture",
        qos: .userInteractive
    )
    private var videoTask: Task<Void, Never>?
    private var captureSession: SimulatorCameraCaptureSessionBox?
    private var captureDelegate: SimulatorCameraCaptureDelegate?

    init(
        surfaceRing: SimulatorCameraSurfaceRing,
        timing: any SimulatorCameraTiming = ContinuousSimulatorCameraTiming(),
        sessionRunner: SimulatorCameraSessionRunner = SimulatorCameraSessionRunner(),
        fileManager: FileManager = FileManager()
    ) {
        self.surfaceRing = surfaceRing
        self.timing = timing
        playback = SimulatorCameraPlayback(surfaceRing: surfaceRing, timing: timing)
        self.sessionRunner = sessionRunner
        self.fileManager = fileManager
    }

    deinit {
        videoTask?.cancel()
        if let captureSession { sessionRunner.stopDetached(captureSession) }
    }

    func configure(_ configuration: SimulatorCameraConfiguration) async throws {
        let source = unwrappedSimulatorCameraSource(configuration)

        await stop()
        switch source {
        case .disabled:
            return
        case .placeholder:
            let playback = playback
            videoTask = Task(priority: .userInitiated) {
                await playback.playPlaceholder()
            }
        case let .image(url):
            guard url.isFileURL,
                  fileManager.isReadableFile(atPath: url.path),
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
            guard url.isFileURL, fileManager.isReadableFile(atPath: url.path) else {
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
            let playback = playback
            videoTask = Task(priority: .userInitiated) {
                await playback.playVideo(
                    url: url,
                    loops: loops
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
        let stoppingVideoTask = videoTask
        stoppingVideoTask?.cancel()
        videoTask = nil
        await stoppingVideoTask?.value
        if let captureSession {
            await sessionRunner.stop(captureSession)
            await withCheckedContinuation { continuation in
                captureQueue.async { continuation.resume() }
            }
        }
        captureSession = nil
        captureDelegate = nil
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
            queue: captureQueue
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

}

private func unwrappedSimulatorCameraSource(
    _ configuration: SimulatorCameraConfiguration
) -> SimulatorCameraConfiguration {
    if case let .targeted(_, source) = configuration {
        return unwrappedSimulatorCameraSource(source)
    }
    return configuration
}

func simulatorAvailableHostCameras() -> [SimulatorHostCameraDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
        mediaType: .video,
        position: .unspecified
    ).devices.map {
        SimulatorHostCameraDevice(id: $0.uniqueID, name: $0.localizedName)
    }
}
