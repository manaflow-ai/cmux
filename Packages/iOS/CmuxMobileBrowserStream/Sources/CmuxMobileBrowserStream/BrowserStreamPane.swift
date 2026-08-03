#if canImport(UIKit)
import CmuxMobileSupport
import Observation
public import UIKit

/// Complete UIKit chrome and interaction owner for one streamed Mac browser.
@MainActor
public final class BrowserStreamPane: UIViewController, UITextFieldDelegate {
    private let state: BrowserStreamSurfaceState
    private let actions: BrowserStreamSurfaceActions
    private var reconnect: () -> Void
    private let surfaceView: BrowserStreamSurfaceView
    private let overlayContainer = UIView()
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let addressField = UITextField()
    private let reloadButton = UIButton(type: .system)
    private let keyboardButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let keyboardVisibility = MobileKeyboardVisibilityObserver()
    private var renderedDialogID: String?
    private var renderedStatusKey = ""

    public init(
        state: BrowserStreamSurfaceState,
        actions: BrowserStreamSurfaceActions,
        reconnect: @escaping () -> Void
    ) {
        self.state = state
        self.actions = actions
        self.reconnect = reconnect
        surfaceView = BrowserStreamSurfaceView(state: state, actions: actions)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func update(reconnect: @escaping () -> Void) {
        self.reconnect = reconnect
        refresh()
    }

    public override func loadView() {
        let root = UIView()
        root.backgroundColor = UIColor(red: 0.055, green: 0.063, blue: 0.075, alpha: 1)

        configureChromeButton(backButton, symbol: "chevron.backward", label: L10n.string("mobile.browserStream.back", defaultValue: "Back"), identifier: "BrowserStreamBackButton", action: #selector(goBack))
        configureChromeButton(forwardButton, symbol: "chevron.forward", label: L10n.string("mobile.browserStream.forward", defaultValue: "Forward"), identifier: "BrowserStreamForwardButton", action: #selector(goForward))
        configureChromeButton(reloadButton, symbol: "arrow.clockwise", label: L10n.string("mobile.browserStream.reload", defaultValue: "Reload"), identifier: "BrowserStreamReloadButton", action: #selector(reloadPage))
        configureChromeButton(keyboardButton, symbol: "keyboard", label: L10n.string("mobile.browserStream.keyboard", defaultValue: "Show Keyboard"), identifier: "BrowserStreamKeyboardButton", action: #selector(toggleKeyboard))

        addressField.borderStyle = .roundedRect
        addressField.backgroundColor = UIColor.quaternarySystemFill.withAlphaComponent(0.5)
        addressField.placeholder = L10n.string("mobile.browserStream.addressPlaceholder", defaultValue: "Search or enter address")
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.textAlignment = .center
        addressField.font = .preferredFont(forTextStyle: .footnote)
        addressField.delegate = self
        addressField.accessibilityIdentifier = "BrowserStreamAddressField"

        let chromeStack = UIStackView(arrangedSubviews: [backButton, forwardButton, addressField, reloadButton, keyboardButton])
        chromeStack.axis = .horizontal
        chromeStack.alignment = .center
        chromeStack.spacing = 10

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        blur.layer.cornerRadius = 24
        blur.clipsToBounds = true
        chromeStack.translatesAutoresizingMaskIntoConstraints = false
        progressView.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(chromeStack)
        blur.contentView.addSubview(progressView)
        NSLayoutConstraint.activate([
            chromeStack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 14),
            chromeStack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -14),
            chromeStack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 9),
            chromeStack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -9),
            progressView.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 18),
            progressView.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -18),
            progressView.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),
        ])

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.translatesAutoresizingMaskIntoConstraints = false
        blur.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(surfaceView)
        root.addSubview(overlayContainer)
        root.addSubview(blur)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            blur.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            blur.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            surfaceView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: root.topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: blur.topAnchor, constant: -10),
            overlayContainer.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
            overlayContainer.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
            overlayContainer.topAnchor.constraint(equalTo: surfaceView.topAnchor),
            overlayContainer.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor),
        ])
        view = root
        refresh()
        observeState()
    }

    private func configureChromeButton(_ button: UIButton, symbol: String, label: String, identifier: String, action: Selector) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func observeState() {
        withObservationTracking {
            _ = state.url
            _ = state.canGoBack
            _ = state.canGoForward
            _ = state.isLoading
            _ = state.progress
            _ = state.connectionStatus
            _ = state.streamStatus
            _ = state.latestFrame
            _ = state.pendingDialog
            _ = keyboardVisibility.isVisible
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.observeState()
            }
        }
    }

    private func refresh() {
        guard isViewLoaded else { return }
        backButton.isEnabled = state.canGoBack
        forwardButton.isEnabled = state.canGoForward
        if !addressField.isFirstResponder { addressField.text = state.url ?? "" }
        let keyboardVisible = keyboardVisibility.isVisible
        keyboardButton.setImage(UIImage(systemName: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard"), for: .normal)
        keyboardButton.accessibilityLabel = keyboardVisible
            ? L10n.string("mobile.browserStream.hideKeyboard", defaultValue: "Hide Keyboard")
            : L10n.string("mobile.browserStream.keyboard", defaultValue: "Show Keyboard")
        progressView.isHidden = !state.isLoading
        progressView.progress = Float(state.progress)
        progressView.accessibilityLabel = L10n.string("mobile.browserStream.loading", defaultValue: "Loading")
        progressView.accessibilityIdentifier = "BrowserStreamProgress"
        refreshOverlay()
    }

    private func refreshOverlay() {
        let statusKey = "\(state.connectionStatus)-\(state.streamStatus)-\(state.latestFrame == nil)"
        let dialogID = state.pendingDialog?.dialogID
        guard statusKey != renderedStatusKey || dialogID != renderedDialogID else { return }
        renderedStatusKey = statusKey
        renderedDialogID = dialogID
        overlayContainer.subviews.forEach { $0.removeFromSuperview() }
        if let status = makeStatusOverlay() { installOverlay(status) }
        if let dialog = state.pendingDialog {
            let card = BrowserStreamDialogCard(dialog: dialog) { [actions] response in
                Task { await actions.respondToDialog(response) }
            }
            installOverlay(card)
        }
    }

    private func makeStatusOverlay() -> UIView? {
        if state.connectionStatus != .connected {
            let reconnecting = state.connectionStatus == .reconnecting
            return statusOverlay(
                title: reconnecting
                    ? L10n.string("mobile.connection.reconnecting", defaultValue: "Reconnecting")
                    : L10n.string("mobile.browserStream.disconnected", defaultValue: "Browser Disconnected"),
                detail: reconnecting
                    ? L10n.string("mobile.connection.reconnectingDescription", defaultValue: "Trying to reach the selected cmux build.")
                    : L10n.string("mobile.browserStream.disconnectedDetail", defaultValue: "Reconnect to the Mac to continue streaming."),
                symbol: reconnecting ? nil : "wifi.slash",
                spinning: reconnecting,
                reconnect: reconnecting ? nil : { [weak self] in self?.reconnect() },
                identifier: "BrowserStreamDisconnectedOverlay"
            )
        }
        if state.streamStatus == .paused {
            return statusOverlay(
                title: L10n.string("mobile.browserStream.paused", defaultValue: "Stream Paused"),
                detail: L10n.string("mobile.browserStream.pausedDetail", defaultValue: "Return to cmux to resume the browser mirror."),
                symbol: "pause.circle",
                identifier: "BrowserStreamPausedOverlay"
            )
        }
        if state.latestFrame == nil {
            return statusOverlay(
                title: L10n.string("mobile.browserStream.waiting", defaultValue: "Waiting for Browser"),
                detail: L10n.string("mobile.browserStream.waitingDetail", defaultValue: "The first frame will appear when the Mac is ready."),
                symbol: "globe",
                identifier: "BrowserStreamPlaceholder"
            )
        }
        return nil
    }

    private func statusOverlay(
        title: String,
        detail: String,
        symbol: String?,
        spinning: Bool = false,
        reconnect: (() -> Void)? = nil,
        identifier: String
    ) -> UIView {
        let root = UIView()
        root.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        root.accessibilityIdentifier = identifier
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        if spinning {
            let spinner = UIActivityIndicatorView(style: .large)
            spinner.color = .white
            spinner.startAnimating()
            stack.addArrangedSubview(spinner)
        } else if let symbol {
            let image = UIImageView(image: UIImage(systemName: symbol))
            image.tintColor = .white
            image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 36)
            stack.addArrangedSubview(image)
        }
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        stack.addArrangedSubview(titleLabel)
        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .white
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        stack.addArrangedSubview(detailLabel)
        if let reconnect {
            var configuration = UIButton.Configuration.filled()
            configuration.title = L10n.string("mobile.workspace.reconnect", defaultValue: "Reconnect")
            configuration.image = UIImage(systemName: "arrow.clockwise")
            configuration.imagePadding = 6
            let button = UIButton(configuration: configuration)
            button.accessibilityIdentifier = "BrowserStreamReconnectButton"
            button.addAction(UIAction { _ in reconnect() }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
        ])
        return root
    }

    private func installOverlay(_ overlay: UIView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: overlayContainer.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: overlayContainer.bottomAnchor),
        ])
    }

    @objc private func goBack() { state.request(.back) }
    @objc private func goForward() { state.request(.forward) }
    @objc private func reloadPage() { state.request(.reload) }

    @objc private func toggleKeyboard() {
        if keyboardVisibility.isVisible {
            addressField.resignFirstResponder()
            state.hideKeyboardForChrome()
            UIApplication.shared.dismissMobileKeyboard()
        } else {
            state.toggleManualKeyboard()
        }
    }

    public func textFieldDidBeginEditing(_ textField: UITextField) {
        textField.textAlignment = .left
        textField.text = state.url ?? textField.text
    }

    public func textFieldDidEndEditing(_ textField: UITextField) {
        textField.textAlignment = .center
        textField.text = state.url ?? ""
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let address = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return false }
        state.request(.navigate(address))
        textField.resignFirstResponder()
        return true
    }
}
#endif
