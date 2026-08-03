import AppKit
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxFoundation
import Observation

/// Native macOS onboarding surface for pairing an iPhone with this Mac.
@MainActor
final class MobilePairingView: NSView {
    struct Snapshot: Equatable {
        let state: MobilePairingModel.State
        let signedInEmail: String?
        let isAuthenticated: Bool
        let isPresentingSignIn: Bool
        let copiedValue: String?
        let showsLegacyPairingCode: Bool
    }

    struct AuthSnapshot: Equatable {
        let isAuthenticated: Bool
        let isPresentingSignIn: Bool
    }

    static let tailscaleDownloadURL = URL(string: "https://tailscale.com/download")!
    static let iphoneAppURL = URL(string: "https://github.com/manaflow-ai/cmux#founders-edition")!

    let model: MobilePairingModel
    let signInModel: AccountSignInModel
    let coordinator: AuthCoordinator?
    let accountFlow: HostAccountFlow?

    var copiedValue: String?
    var copiedValueGeneration = 0
    var showsLegacyPairingCode = false
    var copyFeedbackTask: Task<Void, Never>?

    private let scrollView = NSScrollView(frame: .zero)
    private let documentContainer = MobilePairingDocumentView(frame: .zero)
    private var renderedStack: NSStackView?
    private var lastSnapshot: Snapshot?
    private var lastAuthSnapshot: AuthSnapshot?
    private var refreshTask: Task<Void, Never>?
    private var measurementTask: Task<Void, Never>?
    private var isAttachedToWindow = false
    private var backgroundColor: NSColor?
    private var onRequestPanelFocus: () -> Void
    private let onContentHeightChange: (CGFloat) -> Void

    init(
        model: MobilePairingModel? = nil,
        onContentHeightChange: @escaping (CGFloat) -> Void = { _ in },
        backgroundColor: NSColor? = nil,
        onRequestPanelFocus: @escaping () -> Void = {}
    ) {
        self.model = model ?? MobilePairingModel()
        coordinator = AppDelegate.shared?.auth?.coordinator
        accountFlow = AppDelegate.shared?.auth?.accountFlow
        signInModel = AccountSignInModel(flow: accountFlow)
        self.onContentHeightChange = onContentHeightChange
        self.backgroundColor = backgroundColor
        self.onRequestPanelFocus = onRequestPanelFocus
        super.init(frame: .zero)
        setAccessibilityIdentifier("MobilePairingPanel")
        configureScrollView()
        applyBackgroundColor()
        observeAndRender(force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTask?.cancel()
        measurementTask?.cancel()
        copyFeedbackTask?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !isAttachedToWindow {
            isAttachedToWindow = true
            refresh()
        } else if window == nil, isAttachedToWindow {
            isAttachedToWindow = false
            refreshTask?.cancel()
            refreshTask = nil
            model.stopObserving()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackgroundColor()
        renderedStack?.needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onRequestPanelFocus()
        super.mouseDown(with: event)
    }

    func updatePresentation(
        backgroundColor: NSColor?,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        self.backgroundColor = backgroundColor
        self.onRequestPanelFocus = onRequestPanelFocus
        applyBackgroundColor()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await model.refresh()
        }
    }

    func rerender() {
        lastSnapshot = nil
        observeAndRender(force: true)
    }

    func label(
        _ text: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = GlobalFontMagnification.systemFont(ofSize: size, weight: weight)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func wrappingLabel(
        _ text: String,
        size: CGFloat = 13,
        alignment: NSTextAlignment = .left
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = GlobalFontMagnification.systemFont(ofSize: size)
        field.textColor = .secondaryLabelColor
        field.alignment = alignment
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        return field
    }

    func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
        let view = NSImageView(image: image ?? NSImage())
        view.imageScaling = .scaleProportionallyDown
        view.contentTintColor = color
        return view
    }

    func vertical(
        _ views: [NSView],
        alignment: NSLayoutConstraint.Attribute = .centerX,
        spacing: CGFloat = 12
    ) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = spacing
        return stack
    }

    func button(
        _ title: String,
        style: NSButton.BezelStyle = .rounded,
        action: @escaping () -> Void
    ) -> MobilePairingButton {
        let button = MobilePairingButton(title: title, action: action)
        button.bezelStyle = style
        return button
    }

    func linkButton(_ title: String, action: @escaping () -> Void) -> MobilePairingButton {
        let button = MobilePairingButton(title: title, action: action)
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.font = GlobalFontMagnification.systemFont(ofSize: 12)
        return button
    }

    func centered(_ views: [NSView]) -> NSStackView {
        let stack = vertical(views, spacing: 10)
        stack.alignment = .centerX
        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return stack
    }

    private func configureScrollView() {
        wantsLayer = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        documentContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentContainer
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            documentContainer.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentContainer.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentContainer.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentContainer.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentContainer.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
        ])
    }

    private func applyBackgroundColor() {
        layer?.backgroundColor = (backgroundColor ?? .windowBackgroundColor).cgColor
    }

    private func observeAndRender(force: Bool = false) {
        let snapshot = withObservationTracking {
            Snapshot(
                state: model.state,
                signedInEmail: model.signedInEmail,
                isAuthenticated: coordinator?.isAuthenticated ?? false,
                isPresentingSignIn: accountFlow?.isPresentingSignIn ?? false,
                copiedValue: copiedValue,
                showsLegacyPairingCode: showsLegacyPairingCode
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAndRender() }
        }

        let authSnapshot = AuthSnapshot(
            isAuthenticated: snapshot.isAuthenticated,
            isPresentingSignIn: snapshot.isPresentingSignIn
        )
        if let previous = lastAuthSnapshot,
           previous != authSnapshot,
           isAttachedToWindow,
           (previous.isAuthenticated != authSnapshot.isAuthenticated
            || (previous.isPresentingSignIn && !authSnapshot.isPresentingSignIn)) {
            refresh()
        }
        lastAuthSnapshot = authSnapshot

        guard force || snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        render(snapshot)
    }

    private func render(_ snapshot: Snapshot) {
        renderedStack?.removeFromSuperview()

        let stack = vertical([], alignment: .leading, spacing: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let sections: [NSView] = [
            headerView(),
            requirementsView(snapshot),
            divider(),
            stateContent(snapshot),
        ]
        for section in sections {
            stack.addArrangedSubview(section)
            section.translatesAutoresizingMaskIntoConstraints = false
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        documentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: documentContainer.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: documentContainer.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: documentContainer.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: documentContainer.bottomAnchor, constant: -24),
        ])
        renderedStack = stack
        scheduleHeightReport()
    }

    private func scheduleHeightReport() {
        measurementTask?.cancel()
        measurementTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, let renderedStack else { return }
            layoutSubtreeIfNeeded()
            onContentHeightChange(renderedStack.fittingSize.height + 48)
        }
    }

    private func headerView() -> NSView {
        let heading = label(
            String(localized: "mobile.pairing.window.heading", defaultValue: "Pair your iPhone"),
            size: 20,
            weight: .semibold
        )
        let subheading = wrappingLabel(String(
            localized: "mobile.pairing.window.subheading",
            defaultValue: "iPhones signed in to the same cmux account connect automatically. Scan this code with the cmux app if this Mac doesn't appear on its own."
        ))
        let stack = vertical([heading, subheading], alignment: .leading, spacing: 2)
        subheading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func requirementsView(_ snapshot: Snapshot) -> NSView {
        let signIn = requirementRow(
            title: String(localized: "mobile.pairing.req.signIn.title", defaultValue: "Signed in to cmux"),
            subtitle: snapshot.signedInEmail
                ?? String(localized: "mobile.pairing.req.signIn.subtitle", defaultValue: "Sign in to authorize this Mac for pairing.")
        )
        let iroh = requirementRow(
            title: String(localized: "mobile.pairing.req.iroh.title", defaultValue: "Iroh encrypted transport"),
            subtitle: irohSubtitle(ready: irohReady(for: snapshot.state))
        )
        let tailscaleReady = tailscaleReachable(for: snapshot.state)
        let trailing: NSView? = tailscaleReady == false
            ? linkButton(String(localized: "mobile.pairing.req.tailscale.get", defaultValue: "Get Tailscale")) {
                NSWorkspace.shared.open(Self.tailscaleDownloadURL)
            }
            : nil
        let privateNetwork = requirementRow(
            title: String(localized: "mobile.pairing.req.privateNetwork.title", defaultValue: "Private network (optional)"),
            subtitle: privateNetworkSubtitle(reachable: tailscaleReady),
            trailing: trailing
        )
        return vertical([signIn, iroh, privateNetwork], alignment: .leading, spacing: 12)
    }

    private func requirementRow(title: String, subtitle: String, trailing: NSView? = nil) -> NSView {
        let titleLabel = label(title, weight: .medium)
        let subtitleLabel = wrappingLabel(subtitle, size: 11)
        let text = vertical([titleLabel, subtitleLabel], alignment: .leading, spacing: 2)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let rowViews = trailing.map { [text, $0] } ?? [text]
        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        subtitleLabel.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        if let trailing {
            trailing.setContentHuggingPriority(.required, for: .horizontal)
        }
        return row
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    private func stateContent(_ snapshot: Snapshot) -> NSView {
        switch snapshot.state {
        case .loading:
            if snapshot.isPresentingSignIn {
                return AccountSignInView(model: signInModel, automaticallyStartsSignIn: false)
            }
            return progressContent(String(localized: "mobile.pairing.checking", defaultValue: "Checking…"))
        case .signedOut:
            return AccountSignInView(model: signInModel, automaticallyStartsSignIn: false)
        case .preparing:
            return progressContent(String(localized: "mobile.pairing.preparing", defaultValue: "Preparing a pairing code…"))
        case .needsReachableTransport:
            return needsReachableTransportContent()
        case .failed(let message):
            return failureContent(message)
        case .ready(let ready):
            return readyContent(ready)
        case .connected(let ready):
            return connectedContent(ready)
        }
    }

    private func progressContent(_ message: String) -> NSView {
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        return centered([progress, wrappingLabel(message, alignment: .center)])
    }

    private func needsReachableTransportContent() -> NSView {
        let body = wrappingLabel(String(
            localized: "mobile.pairing.needsReachableTransport.body",
            defaultValue: "Iroh has not registered this Mac yet, and no Tailscale compatibility route is available. Check the Mac's connection, or enable Tailscale on both devices, then refresh."
        ), alignment: .center)
        let tailscale = button(
            String(localized: "mobile.pairing.req.tailscale.get", defaultValue: "Get Tailscale")
        ) { NSWorkspace.shared.open(Self.tailscaleDownloadURL) }
        let refresh = button(
            String(localized: "mobile.pairing.refresh", defaultValue: "Refresh Code")
        ) { [weak self] in self?.refresh() }
        refresh.controlSize = .small
        return centered([
            symbol("network.slash", pointSize: 28, color: .systemOrange),
            body,
            tailscale,
            refresh,
        ])
    }

    private func failureContent(_ message: String) -> NSView {
        let retry = button(
            String(localized: "mobile.pairing.retry", defaultValue: "Try Again")
        ) { [weak self] in self?.refresh() }
        retry.keyEquivalent = "\r"
        return centered([
            symbol("exclamationmark.triangle", pointSize: 28, color: .systemOrange),
            wrappingLabel(message, alignment: .center),
            retry,
        ])
    }

    private func readyContent(_ ready: MobilePairingModel.Ready) -> NSView {
        var sections: [NSView] = []
        if ready.reachableViaTailscale {
            sections.append(manualFallback(ready))
        }

        let qr = MobilePairingQRImageView(payload: displayedAttachURL(ready))
        qr.translatesAutoresizingMaskIntoConstraints = false
        let qrContainer = NSView(frame: .zero)
        qrContainer.addSubview(qr)
        NSLayoutConstraint.activate([
            qr.centerXAnchor.constraint(equalTo: qrContainer.centerXAnchor),
            qr.topAnchor.constraint(equalTo: qrContainer.topAnchor),
            qr.bottomAnchor.constraint(equalTo: qrContainer.bottomAnchor),
            qr.widthAnchor.constraint(lessThanOrEqualTo: qrContainer.widthAnchor),
            qr.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        let waitingLabel = wrappingLabel(
            String(localized: "mobile.pairing.waiting", defaultValue: "Waiting for your iPhone…"),
            alignment: .center
        )
        let waiting = NSStackView(views: [progress, waitingLabel])
        waiting.orientation = .horizontal
        waiting.alignment = .centerY
        waiting.spacing = 6

        let code = vertical(
            [qrContainer, waiting, pairingCodeModeControls(ready)],
            alignment: .centerX,
            spacing: 14
        )
        qrContainer.widthAnchor.constraint(equalTo: code.widthAnchor).isActive = true
        sections.append(code)
        sections.append(stepsView())

        let refresh = button(
            String(localized: "mobile.pairing.refresh", defaultValue: "Refresh Code")
        ) { [weak self] in self?.refresh() }
        refresh.controlSize = .small
        let refreshRow = NSStackView(views: [NSView(), refresh])
        refreshRow.orientation = .horizontal
        refreshRow.alignment = .centerY
        sections.append(refreshRow)

        let result = vertical(sections, alignment: .leading, spacing: 18)
        for section in sections {
            section.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true
        }
        return result
    }

    private func displayedAttachURL(_ ready: MobilePairingModel.Ready) -> String {
        guard showsLegacyPairingCode, let legacyAttachURL = ready.legacyAttachURL else {
            return ready.attachURL
        }
        return legacyAttachURL
    }

    private func pairingCodeModeControls(_ ready: MobilePairingModel.Ready) -> NSView {
        let detail: String
        if ready.legacyAttachURL != nil {
            detail = showsLegacyPairingCode
                ? String(
                    localized: "mobile.pairing.codeMode.legacyDetail",
                    defaultValue: "Tailscale code: for the Tailscale connection method and older iPhone apps. The iPhone must be on the same Tailscale network."
                )
                : String(
                    localized: "mobile.pairing.codeMode.irohDetail",
                    defaultValue: "Iroh code: encrypted end to end, with direct and relay paths selected automatically."
                )
        } else if ready.primaryTransport == .iroh {
            detail = String(
                localized: "mobile.pairing.codeMode.irohDetail",
                defaultValue: "Iroh code: encrypted end to end, with direct and relay paths selected automatically."
            )
        } else {
            detail = String(
                localized: "mobile.pairing.codeMode.legacyOnlyDetail",
                defaultValue: "Iroh is unavailable, so this code uses the Tailscale compatibility path."
            )
        }

        let detailLabel = wrappingLabel(detail, size: 11, alignment: .center)
        detailLabel.preferredMaxLayoutWidth = 440
        var views: [NSView] = [detailLabel]
        if ready.legacyAttachURL != nil {
            let title = showsLegacyPairingCode
                ? String(localized: "mobile.pairing.codeMode.useIroh", defaultValue: "Use Iroh Code")
                : String(localized: "mobile.pairing.codeMode.useLegacy", defaultValue: "Use Tailscale Pairing Code")
            views.append(linkButton(title) { [weak self] in
                guard let self else { return }
                showsLegacyPairingCode.toggle()
                rerender()
            })
        }
        return vertical(views, alignment: .centerX, spacing: 6)
    }

    private func irohReady(for state: MobilePairingModel.State) -> Bool? {
        switch state {
        case .ready(let ready), .connected(let ready): ready.reachableViaIroh
        case .needsReachableTransport: false
        default: nil
        }
    }

    private func tailscaleReachable(for state: MobilePairingModel.State) -> Bool? {
        switch state {
        case .ready(let ready), .connected(let ready): ready.reachableViaTailscale
        case .needsReachableTransport: false
        default: nil
        }
    }

    private func irohSubtitle(ready: Bool?) -> String {
        switch ready {
        case true:
            String(localized: "mobile.pairing.req.iroh.ready", defaultValue: "Ready. Iroh connects directly when possible and uses a cmux relay when needed.")
        case false:
            String(localized: "mobile.pairing.req.iroh.unavailable", defaultValue: "Not ready. A Tailscale compatibility route may still be available.")
        case nil:
            String(localized: "mobile.pairing.req.iroh.preparing", defaultValue: "Registering this Mac's encrypted endpoint.")
        }
    }

    private func privateNetworkSubtitle(reachable: Bool?) -> String {
        switch reachable {
        case true:
            String(localized: "mobile.pairing.req.privateNetwork.reachable", defaultValue: "Tailscale is available for older-client compatibility and may become a direct Iroh path after admission.")
        case false:
            String(localized: "mobile.pairing.req.privateNetwork.missing", defaultValue: "Not detected. Iroh pairing does not require Tailscale.")
        case nil:
            String(localized: "mobile.pairing.req.privateNetwork.hint", defaultValue: "After Iroh admits the phone, Tailscale, another VPN, or the same LAN may become a direct path.")
        }
    }
}

@MainActor
final class MobilePairingButton: NSButton {
    private let closure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        closure = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(invoke)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() { closure() }
}

private final class MobilePairingDocumentView: NSView {
    override var isFlipped: Bool { true }
}
