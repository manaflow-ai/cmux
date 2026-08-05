#if os(iOS)
@preconcurrency import AVFoundation
import CmuxMobileCamera
import CmuxMobileSupport
import CmuxMobileWorkspace
import UIKit

/// Native camera-permission and QR-scanning surface for computer pairing.
@MainActor
final class MobilePairingScannerViewController: UIViewController {
    private let coordinator: MobileRootCoordinator
    private let authorization = CameraAuthorization()
    private var authorizationTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var captureController: QRCodeCaptureController?

    init(coordinator: MobileRootCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("mobile.pairing.scannerTitle", defaultValue: "Scan QR Code")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        authorizationTask?.cancel()
        scanTask?.cancel()
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .systemBackground
        root.accessibilityIdentifier = "MobilePairingScannerSheet"
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("mobile.pairing.scannerCancel", defaultValue: "Cancel"),
            primaryAction: UIAction { [weak self] _ in self?.coordinator.dismissPairing() }
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "MobileScannerCancelButton"
        renderAuthorization(authorization.videoStatus)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if authorization.videoStatus != .notDetermined {
            renderAuthorization(authorization.videoStatus)
        }
    }

    private func renderAuthorization(_ status: AVAuthorizationStatus) {
        removeContent()
        switch status {
        case .authorized:
            mountScanner()
        case .notDetermined:
            mountProgress()
            authorizationTask?.cancel()
            authorizationTask = Task { [weak self] in
                guard let self else { return }
                let status = await authorization.requestVideoAccess()
                guard !Task.isCancelled else { return }
                renderAuthorization(status)
            }
        case .denied:
            mountUnavailable(
                title: L10n.string("mobile.pairing.cameraDenied", defaultValue: "Camera Access Required"),
                message: L10n.string("mobile.pairing.cameraDeniedDescription", defaultValue: "Allow camera access in Settings to scan the QR code from your Mac."),
                showsSettings: true
            )
        case .restricted:
            mountUnavailable(
                title: L10n.string("mobile.pairing.cameraDenied", defaultValue: "Camera Access Required"),
                message: L10n.string("mobile.pairing.cameraRestrictedDescription", defaultValue: "Camera access is restricted on this device. Use a pairing link or the manual form instead."),
                showsSettings: false
            )
        @unknown default:
            mountUnavailable(
                title: L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable"),
                message: nil,
                showsSettings: false
            )
        }
    }

    private func removeContent() {
        authorizationTask?.cancel()
        authorizationTask = nil
        scanTask?.cancel()
        scanTask = nil
        if let captureController {
            captureController.willMove(toParent: nil)
            captureController.view.removeFromSuperview()
            captureController.removeFromParent()
            self.captureController = nil
        }
        view.subviews.forEach { $0.removeFromSuperview() }
    }

    private func mountScanner() {
        let stream = QRCodeScanStream()
        let capture = QRCodeCaptureController(
            stream: stream,
            accepts: MobilePairingScannerPolicy.acceptsCode,
            unavailableText: L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable")
        )
        addChild(capture)
        capture.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(capture.view)
        NSLayoutConstraint.activate([
            capture.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            capture.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            capture.view.topAnchor.constraint(equalTo: view.topAnchor),
            capture.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        capture.didMove(toParent: self)
        captureController = capture
        scanTask = Task { [weak self] in
            for await code in stream.codes {
                guard let self, !Task.isCancelled else { return }
                coordinator.connectScannedPairingCode(code)
                return
            }
        }
    }

    private func mountProgress() {
        let progress = UIActivityIndicatorView(style: .large)
        progress.startAnimating()
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.accessibilityIdentifier = "MobilePairingScannerPermissionProgress"
        view.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func mountUnavailable(title: String, message: String?, showsSettings: Bool) {
        let image = UIImageView(image: UIImage(systemName: "camera.fill"))
        image.tintColor = .secondaryLabel
        image.contentMode = .scaleAspectFit
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 54)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.isHidden = message == nil

        var buttons: [UIView] = []
        if showsSettings {
            let settings = UIButton(type: .system)
            var configuration = UIButton.Configuration.filled()
            configuration.title = L10n.string("mobile.pairing.openSettings", defaultValue: "Open Settings")
            configuration.cornerStyle = .capsule
            settings.configuration = configuration
            settings.accessibilityIdentifier = "MobilePairingOpenSettingsButton"
            settings.addAction(UIAction { _ in
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }, for: .touchUpInside)
            buttons.append(settings)
        }
        let manual = UIButton(type: .system)
        var manualConfiguration = UIButton.Configuration.bordered()
        manualConfiguration.title = L10n.string("mobile.pairing.enterManually", defaultValue: "Enter Manually")
        manualConfiguration.cornerStyle = .capsule
        manual.configuration = manualConfiguration
        manual.accessibilityIdentifier = "MobilePairingEnterManuallyButton"
        manual.addAction(UIAction { [weak self] _ in self?.coordinator.presentAddComputer() }, for: .touchUpInside)
        buttons.append(manual)

        let stack = UIStackView(arrangedSubviews: [image, titleLabel, messageLabel] + buttons)
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            image.heightAnchor.constraint(equalToConstant: 90),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])
        view.accessibilityIdentifier = showsSettings ? "MobilePairingCameraDenied" : "MobilePairingCameraRestricted"
    }
}
#endif
