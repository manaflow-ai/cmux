#if os(iOS)
@preconcurrency import AVFoundation
public import UIKit

/// A `UIViewController` that runs a QR-capture `AVCaptureSession` and yields
/// accepted codes through a ``QRCodeScanStream``.
///
/// Owns the capture input, the metadata output (filtered to QR), and the
/// preview layer. The session is started/stopped with the view's
/// appear/disappear lifecycle. When no camera input can be configured it shows
/// the injected `unavailableText` label instead.
///
/// Construct via ``init(stream:accepts:unavailableText:)``; the host SwiftUI
/// wrapper passes the localized "Camera Unavailable" copy so this leaf service
/// stays free of a localization dependency.
public final class QRCodeCaptureController: UIViewController {
    private let stream: QRCodeScanStream
    private let receiver: QRCodeMetadataReceiver
    private let unavailableText: String
    private let captureSession = AVCaptureSession()
    // Apple guidance: configure/start/stop the session off the main thread to
    // avoid blocking UI; this queue serializes those session mutations.
    private let sessionQueue = DispatchQueue(label: "dev.cmux.mobile.qr-scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false

    /// Creates a QR-capture controller.
    /// - Parameters:
    ///   - stream: The scan stream that accepted codes are yielded into.
    ///   - accepts: Predicate deciding whether a decoded string is accepted.
    ///   - unavailableText: Localized copy shown when no camera is available.
    public init(
        stream: QRCodeScanStream,
        accepts: @escaping @Sendable (String) -> Bool,
        unavailableText: String
    ) {
        self.stream = stream
        self.receiver = QRCodeMetadataReceiver(stream: stream, accepts: accepts)
        self.unavailableText = unavailableText
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSession()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func configureSession() {
        guard let videoDevice = bestCameraDevice(),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(videoInput) else {
            showUnavailable()
            return
        }
        captureSession.addInput(videoInput)
        // More pixels give the detector more modules to resolve; 1080p is
        // ample for a pairing code at arm's length without 4K's latency and
        // heat. Falls back to the device default when unsupported.
        if captureSession.canSetSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080
        }
        tuneForScreenQRScanning(videoDevice)

        let metadataOutput = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(metadataOutput) else {
            showUnavailable()
            return
        }
        captureSession.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(receiver, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]
        // rectOfInterest is deliberately left at its default, the full
        // frame. It is expressed in normalized landscape-oriented capture
        // coordinates, not view coordinates: anyone scoping it to an
        // on-screen viewfinder must convert through the preview layer's
        // metadataOutputRectConverted(fromLayerRect:), or the scan region
        // will not be where the box is drawn and codes that look centered
        // will not decode.

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        isConfigured = true
    }

    private func startSession() {
        guard isConfigured else { return }
        sessionQueue.async { [captureSession] in
            guard !captureSession.isRunning else { return }
            captureSession.startRunning()
        }
    }

    private func stopSession() {
        guard isConfigured else { return }
        sessionQueue.async { [captureSession] in
            guard captureSession.isRunning else { return }
            captureSession.stopRunning()
        }
    }

    private func showUnavailable() {
        let label = UILabel()
        label.text = unavailableText
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
private extension QRCodeCaptureController {
    /// The camera closest to what the system Camera app uses for QR scanning: a
    /// virtual multi-lens device switches constituent cameras automatically,
    /// including to the close-focusing ultra-wide. A bare wide-angle on recent
    /// Pro phones cannot focus nearer than roughly 20 cm (exactly where people
    /// hold the phone to a code on a Mac screen), so it hunts while the Camera
    /// app quietly switches lenses.
    func bestCameraDevice() -> AVCaptureDevice? {
        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
        ]
        for deviceType in preferredTypes {
            if let device = AVCaptureDevice.default(deviceType, for: .video, position: .back) {
                return device
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// Focus and exposure tuning for a code shown on a backlit screen at arm's
    /// length: continuous autofocus restricted to the near range (less hunting
    /// at infinity), smooth autofocus off (a video-recording nicety that slows
    /// refocus snaps), continuous exposure, and low-light boost for dim rooms.
    /// Best-effort: every step is capability-guarded, and defaults still scan if
    /// the lock fails. No torch on purpose: the Mac screen is its own light
    /// source, and a torch reflecting off glossy glass washes the code out.
    func tuneForScreenQRScanning(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = false
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = true
        }
    }
}
#endif
