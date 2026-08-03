#if canImport(UIKit)
import CmuxMobileSupport
import Observation
public import UIKit

/// Complete UIKit browser pane with native navigation chrome and a WebKit
/// content owner.
@MainActor
public final class MobileBrowserPane: UIViewController, UITextFieldDelegate {
    private let state: BrowserSurfaceState
    private var onClose: () -> Void
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let addressField = UITextField()
    private let reloadOrStopButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let browserView: MobileBrowserView

    public init(state: BrowserSurfaceState, onClose: @escaping () -> Void) {
        self.state = state
        self.onClose = onClose
        browserView = MobileBrowserView(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(onClose: @escaping () -> Void) {
        self.onClose = onClose
        refreshChrome()
    }

    public override func loadView() {
        let root = UIView()
        root.backgroundColor = .systemBackground

        configureButton(backButton, symbol: "chevron.backward", accessibilityLabel: L10n.string("mobile.browser.back", defaultValue: "Back"), identifier: "MobileBrowserBackButton", action: #selector(goBack))
        configureButton(forwardButton, symbol: "chevron.forward", accessibilityLabel: L10n.string("mobile.browser.forward", defaultValue: "Forward"), identifier: "MobileBrowserForwardButton", action: #selector(goForward))
        configureButton(closeButton, symbol: "xmark", accessibilityLabel: L10n.string("mobile.browser.close", defaultValue: "Close Browser"), identifier: "MobileBrowserCloseButton", action: #selector(closeBrowser))

        addressField.borderStyle = .roundedRect
        addressField.placeholder = L10n.string("mobile.browser.addressPlaceholder", defaultValue: "Search or enter address")
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.clearButtonMode = .whileEditing
        addressField.delegate = self
        addressField.accessibilityIdentifier = "MobileBrowserAddressField"

        reloadOrStopButton.addTarget(self, action: #selector(reloadOrStop), for: .touchUpInside)

        let chrome = UIStackView(arrangedSubviews: [backButton, forwardButton, addressField, reloadOrStopButton, closeButton])
        chrome.axis = .horizontal
        chrome.alignment = .center
        chrome.spacing = 12
        chrome.isLayoutMarginsRelativeArrangement = true
        chrome.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        chrome.backgroundColor = .secondarySystemBackground

        progressView.accessibilityIdentifier = "MobileBrowserProgress"
        progressView.trackTintColor = .clear

        chrome.translatesAutoresizingMaskIntoConstraints = false
        progressView.translatesAutoresizingMaskIntoConstraints = false
        browserView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(chrome)
        root.addSubview(progressView)
        root.addSubview(browserView)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            progressView.topAnchor.constraint(equalTo: chrome.bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),
            browserView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            browserView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            browserView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            browserView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        refreshChrome()
        observeState()
    }

    private func configureButton(_ button: UIButton, symbol: String, accessibilityLabel: String, identifier: String, action: Selector) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func observeState() {
        withObservationTracking {
            _ = state.addressText
            _ = state.canGoBack
            _ = state.canGoForward
            _ = state.isLoading
            _ = state.estimatedProgress
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshChrome()
                self.observeState()
            }
        }
    }

    private func refreshChrome() {
        guard isViewLoaded else { return }
        backButton.isEnabled = state.canGoBack
        forwardButton.isEnabled = state.canGoForward
        if !addressField.isFirstResponder {
            addressField.text = state.addressText
        }
        let isLoading = state.isLoading
        reloadOrStopButton.setImage(UIImage(systemName: isLoading ? "xmark.circle" : "arrow.clockwise"), for: .normal)
        reloadOrStopButton.accessibilityLabel = isLoading
            ? L10n.string("mobile.browser.stop", defaultValue: "Stop")
            : L10n.string("mobile.browser.reload", defaultValue: "Reload")
        reloadOrStopButton.accessibilityIdentifier = isLoading ? "MobileBrowserStopButton" : "MobileBrowserReloadButton"
        progressView.isHidden = !isLoading
        progressView.progress = Float(state.estimatedProgress)
    }

    @objc private func goBack() { state.request(.goBack) }
    @objc private func goForward() { state.request(.goForward) }
    @objc private func closeBrowser() { onClose() }

    @objc private func reloadOrStop() {
        state.request(state.isLoading ? .stopLoading : .reload)
    }

    public func textFieldDidBeginEditing(_ textField: UITextField) {
        state.isAddressEditing = true
    }

    public func textFieldDidEndEditing(_ textField: UITextField) {
        state.isAddressEditing = false
        state.addressText = textField.text ?? ""
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        state.addressText = textField.text ?? ""
        guard state.submitAddress() else { return false }
        textField.resignFirstResponder()
        return true
    }
}
#endif
