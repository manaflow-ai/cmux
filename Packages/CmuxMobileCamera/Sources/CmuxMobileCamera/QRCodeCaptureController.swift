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
        guard let videoDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(videoInput) else {
            showUnavailable()
            return
        }
        captureSession.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(metadataOutput) else {
            showUnavailable()
            return
        }
        captureSession.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(receiver, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]

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
#endif
