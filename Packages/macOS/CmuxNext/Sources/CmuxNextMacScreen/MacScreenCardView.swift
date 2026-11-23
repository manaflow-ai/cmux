import AppKit
import CmuxNextDesign
import CmuxNextDevices
import Observation

/// The card over a Mac Screen tab's screen (AppKit): connecting, waiting,
/// failed, ended, and a device hub tab's Connect card and every way a request
/// or session ends. It builds its content again only when what it says
/// changes (the card, the Mac's name, the failure's detail); the pane centers
/// it at its fitting size.
@MainActor
final class MacScreenCardView: MacScreenThemedView {
    /// What the card says.
    struct Shown: Equatable {
        var card: MacScreenCard?
        var name: String
        var failedDetail: String
        /// The type scale the card was built at (`MacScreenType.sizes`).
        var typeSizes = MacScreenType.sizes
        /// The viewer look the card's surface is drawn in.
        var look = MacScreenViewerLook.current
        /// The session's link is up (read only by a full-pane look, whose connect steps name it).
        var linkConnected = false
        /// The offline card's Start cmux on NAME and its run (``MacScreenDeviceSetupRow/none`` on every other card).
        var setup = MacScreenDeviceSetupRow.none
    }

    /// What the offline card offers of Start cmux: only a device hub tab whose Mac is offline. A Mac Screen
    /// host is always a Mac.
    static func setup(_ model: MacScreenPaneModel) -> MacScreenDeviceSetupRow {
        guard case .hubRefused(.hostOffline, _)? = model.card, let id = model.hub?.deviceID, let setup = model.deviceSetup else { return .none }
        return setup.row(id: id, isMac: true, online: false)
    }

    static let width: CGFloat = 340
    /// The card's spinner: the side of a regular `ProgressView`.
    static let spinnerSide: CGFloat = 32
    private static let textWidth = width - 48
    /// The info circle after a status line, and the gap before it.
    private static let infoGap: CGFloat = 6
    private static let infoRoom: CGFloat = 20

    private let model: MacScreenPaneModel
    private let actions: MacScreenChromeActions
    /// The card's surface: its fill and corners follow the viewer look (``MacScreenViewerStyle``).
    private var background = MacScreenCardView.makeBackground(MacScreenViewerStyle.current)
    private var backgroundConstraints: [NSLayoutConstraint] = []
    private var backgroundLook = MacScreenViewerLook.current
    private var backgroundQuiet = false
    private let stack = MacScreenStack.make(.vertical, spacing: 12, alignment: .centerX,
                                            insets: NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24))
    private(set) var shown: Shown?
    /// The shown card is transient and its look draws those quietly (``MacScreenViewerStyle/cardQuietTransient``).
    private var quiet: Bool { shown.map { $0.look.style.cardQuietTransient && $0.card?.isTransient == true } ?? false }

    init(model: MacScreenPaneModel, actions: MacScreenChromeActions) {
        self.model = model
        self.actions = actions
        super.init(frame: .zero)
        setAccessibilityElement(false)
        installBackground(model.viewerLook)
        render()
    }

    private static func makeBackground(_ style: MacScreenViewerStyle, quiet: Bool = false) -> MacScreenFill {
        let background = MacScreenFill(quiet ? \.noFill : style.cardFill, shape: .rounded(style.cardCornerRadius ?? Metrics.panelCornerRadius),
                                       bordered: style.cardBordered && !quiet)
        background.setAccessibilityElement(true)
        background.setAccessibilityRole(.group)
        background.setAccessibilityIdentifier("macScreen.card")
        background.translatesAutoresizingMaskIntoConstraints = true
        background.autoresizingMask = [.width, .height]
        return background
    }

    /// Puts a surface in `look` behind the stack (the first one, and again when the look changes).
    private func installBackground(_ look: MacScreenViewerLook) {
        NSLayoutConstraint.deactivate(backgroundConstraints)
        background.removeFromSuperview()
        background = Self.makeBackground(look.style, quiet: quiet)
        backgroundLook = look
        backgroundQuiet = quiet
        background.isHidden = shown?.card == nil
        addSubview(background)
        background.addSubview(stack)
        // The card's frame comes from the pane (`fittingSize`): the far edges give way while it is not laid out yet.
        let trailing = stack.trailingAnchor.constraint(equalTo: background.trailingAnchor)
        let bottom = stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        trailing.priority = .init(999)
        bottom.priority = .init(999)
        backgroundConstraints = [
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: look.style.cardWidth ?? Self.width),
            trailing,
            bottom,
        ]
        NSLayoutConstraint.activate(backgroundConstraints)
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    /// The card's size: its width, and the height of what it says at that width (zero with no card).
    override var fittingSize: NSSize {
        guard shown?.card != nil else { return .zero }
        return NSSize(width: shown?.look.style.cardWidth ?? Self.width, height: ceil(stack.fittingSize.height))
    }

    override func layout() {
        super.layout()
        background.frame = bounds
    }

    private func render() {
        let next = withObservationTracking { () -> Shown in
            var next = Shown(card: model.card, name: model.name, failedDetail: Self.failedDetail(model.card, model), look: model.viewerLook, setup: Self.setup(model))
            if next.look.style.cardLayout == .fullPane { next.linkConnected = model.session?.linkConnected ?? false }
            return next
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.render() }
        }
        guard next != shown else { return }
        shown = next
        let heldKeyboard = paneHoldsKeyboard
        if next.look != backgroundLook || quiet != backgroundQuiet { installBackground(next.look) }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        background.isHidden = next.card == nil
        if let card = next.card {
            switch next.look.style.cardLayout {
            case .standard: content(card)
            case .fullPane: MacScreenFullPaneState(card: card, shown: next, model: model, actions: actions).build(in: stack)
            }
        }
        paint(background)
        linkKeys(refocus: heldKeyboard)
        // The pane centers the card at its new size.
        superview?.needsLayout = true
    }

    /// The button the keyboard lands on while this card shows: its primary button, else its first.
    private(set) var keyButton: MacScreenButton?

    /// The pane this card sits in holds the keyboard (its screen, or one of this card's buttons).
    private var paneHoldsKeyboard: Bool {
        guard let pane = superview, let focused = window?.firstResponder as? NSView else { return false }
        return focused === pane || focused.isDescendant(of: pane)
    }

    /// Makes the card's buttons a keyboard loop: Tab and Shift-Tab move between them, Space presses the
    /// focused one, Return the primary. A pane that held the keyboard moves it to the new card's
    /// button, or back to the screen once no card shows (a CLI-opened share's chooser).
    private func linkKeys(refocus: Bool) {
        let buttons = Self.buttons(in: stack)
        for (index, button) in buttons.enumerated() {
            button.takesKeyFocus = true
            button.nextKeyView = buttons[(index + 1) % buttons.count]
        }
        keyButton = buttons.first { $0.role == .primary } ?? buttons.first
        if refocus { actions.focusScreen() }
    }

    private static func buttons(in view: NSView) -> [MacScreenButton] {
        view.subviews.flatMap { subview -> [MacScreenButton] in // visible-only: a card holds a few rows of text and buttons
            if let button = subview as? MacScreenButton { return [button] }
            return buttons(in: subview)
        }
    }

    /// The failure's detail for `card`: the failed card's (``MacScreenPaneModel/failedDetail``), or
    /// for a hub end that says the stream failed, the host's reason when it gave one; else empty.
    static func failedDetail(_ card: MacScreenCard?, _ model: MacScreenPaneModel) -> String {
        switch card {
        case .failed?: model.failedDetail
        case .hubEnded(.failed)?, .hubRevoked(.failed)?: model.hubFailureDetail ?? ""
        default: ""
        }
    }

    // MARK: Pieces

    /// The card's one line of status. Anything more it has to say hangs on an info circle at the line's end (``detail(_:)``).
    private func title(_ text: String) {
        let line = MacScreenText(text, font: quiet ? MacScreenType.body : MacScreenType.cardTitle, ink: quiet ? \.secondary : \.primary,
                                 wraps: true, alignment: .center, width: Self.textWidth - Self.infoRoom)
        stack.addArrangedSubview(MacScreenStack.make(.horizontal, spacing: Self.infoGap, alignment: .centerY, [line]))
    }

    /// An explanation, behind an info circle after the status line with a hover: the card never prints it (Leo, 2026-11-23:
    /// "THERE ARE HOVERS AND QUESTION MARK CIRCLES AND INFO CIRCLES"). A quiet card has none.
    private func detail(_ text: String) {
        guard !quiet, !text.isEmpty, let line = stack.arrangedSubviews.last as? NSStackView else { return }
        let info = MacScreenGlyph("info.circle", font: MacScreenType.body, ink: \.secondary)
        info.toolTip = text
        info.setAccessibilityElement(true)
        info.setAccessibilityRole(.staticText)
        info.setAccessibilityLabel(text)
        info.setAccessibilityIdentifier("macScreen.card.info")
        line.addArrangedSubview(info)
    }

    private func spinner() {
        let spinner = StatusIndicatorView.spinner()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        // A quiet card's mark: small and faint, as the terminal's status banner draws it.
        let side = quiet ? MacScreenCard.quietMarkSide : Self.spinnerSide
        spinner.alphaValue = quiet ? MacScreenCard.quietMarkAlpha : 1
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: side),
            spinner.heightAnchor.constraint(equalToConstant: side),
        ])
        spinner.spin(true)
        stack.addArrangedSubview(spinner)
    }

    private func buttons(_ buttons: [NSView]) {
        stack.addArrangedSubview(MacScreenStack.make(.horizontal, spacing: 8, alignment: .centerY, buttons))
    }

    private func closeTab(id: String? = nil) -> MacScreenButton {
        MacScreenButton(L.t("macScreen.card.closeTab", "Close Tab"), id: id) { [weak self] in self?.actions.closeTab() }
    }

    private func cancel(_ run: @escaping @MainActor (MacScreenChromeActions) -> Void, id: String? = nil) -> MacScreenButton {
        MacScreenButton(L.t("macScreen.card.cancel", "Cancel"), id: id) { [weak self] in
            guard let self else { return }
            run(actions)
        }
    }

    private func primary(_ title: String, hint: CmuxDialogKeyHint? = nil, id: String? = nil,
                         _ run: @escaping @MainActor (MacScreenChromeActions) -> Void) -> MacScreenButton {
        MacScreenButton(title, role: .primary, hint: hint, id: id) { [weak self] in
            guard let self else { return }
            run(actions)
        }
    }

    // MARK: Cards

    private var name: String { shown?.name ?? model.name }
    /// A hub end's host reason, when the shown card has one (``failedDetail(_:_:)``).
    private var hostReason: String? { shown?.failedDetail.isEmpty == false ? shown?.failedDetail : nil }

    private func content(_ card: MacScreenCard) {
        switch card {
        case .unsupported:
            title(L.t("macScreen.card.linksGoneTitle", "Pairing Links Are No Longer Supported"))
            detail(L.t("macScreen.card.linksGoneBody", "Screen Sharing now connects the Macs signed in to your cmux account. Open Screen Sharing to see them."))
            buttons([closeTab(id: "macScreen.card.closeTab"), primary(L.t("macScreen.card.openHome", "Open Screen Sharing")) { $0.openHome() }])
        case let .connecting(reconnecting):
            spinner()
            title(reconnecting ? L.t("macScreen.card.reconnecting", "Reconnecting…")
                : String(format: L.t("macScreen.card.connecting", "Connecting to %@…"), name))
            buttons([cancel { $0.disconnect() }])
        case .waitingForPicture:
            spinner()
            title(L.t("macScreen.card.waiting", "Waiting for the screen…"))
        case .failed:
            // The session's free-form message can quote the signaling URL (with the room id): never
            // shown. Only a cause a side named (the host's reason, the link's) is, in failedDetail.
            title(L.t("macScreen.card.failedTitle", "Couldn’t connect"))
            detail(shown?.failedDetail ?? model.failedDetail)
            buttons([closeTab(), primary(L.t("macScreen.card.retry", "Try Again"), hint: .return, id: "macScreen.card.retry") { $0.connect() }])
        case .ended:
            title(L.t("macScreen.card.endedTitle", "Disconnected"))
            buttons([closeTab(), primary(L.t("macScreen.card.reconnect", "Reconnect"), hint: .return, id: "macScreen.card.reconnect") { $0.connect() }])
        case .hubConnect, .hubRequesting, .hubWaiting, .hubDeclined, .hubRefused, .hubRevoked, .hubAccessLowered, .hubEnded:
            hubContent(card)
        }
    }

    /// A device hub tab's cards: Connect, waiting, and every way a request or session ends.
    private func hubContent(_ card: MacScreenCard) {
        switch card {
        case .hubConnect:
            title(String(format: L.t("macScreen.hub.connectTitle", "Connect to %@"), name))
            detail(L.t("macScreen.hub.connectBody", "View Only shows the screen. Full Control also sends your clicks and keys."))
            scopeButtons(primary: .full)
        case let .hubRequesting(scope):
            spinner()
            title(String(format: L.t("macScreen.hub.requesting", "Connecting to %@…"), name))
            detail(scope.title)
            buttons([cancel({ $0.cancelRequest() }, id: "macScreen.hub.cancel")])
        case let .hubWaiting(scope):
            spinner()
            title(String(format: L.t("macScreen.hub.waitingTitle", "Waiting for %@ to approve…"), name))
            detail(String(format: L.t("macScreen.hub.waitingOwnerBody", "You asked for %@. Its owner needs to allow it."), scope.title))
            buttons([cancel({ $0.cancelRequest() }, id: "macScreen.hub.cancel")])
        case let .hubDeclined(scope):
            title(L.t("macScreen.hub.declinedTitle", "Declined"))
            detail(String(format: L.t("macScreen.hub.declinedBody", "%@ declined your request."), name))
            buttons([closeTab(), primary(L.t("macScreen.hub.askAgain", "Ask Again"), id: "macScreen.hub.askAgain") { $0.requestScope(scope) }])
        case let .hubRefused(refusal, requested):
            refusedContent(refusal, requested: requested)
        case let .hubRevoked(reason):
            // Ends from either side come as revocations too: only a lost permission or device reads as removed access.
            let removed = reason.removesAccess
            title(removed ? L.t("macScreen.hub.revokedTitle", "Access Removed") : L.t("macScreen.card.endedTitle", "Disconnected"))
            detail(hostReason ?? reason.text(host: name))
            var row = [closeTab()]
            if reason.canReconnect {
                row.append(primary(L.t("macScreen.hub.connectAgain", "Connect Again"), id: "macScreen.hub.connectAgain") { $0.connect() })
            }
            buttons(row)
        case .hubAccessLowered:
            title(L.t("macScreen.hub.loweredTitle", "Access Changed to View Only"))
            detail(String(format: L.t("macScreen.hub.loweredBody", "%@ now lets this Mac view its screen but not control it."), name))
            buttons([closeTab(), primary(L.t("macScreen.hub.viewInstead", "View Instead"), id: "macScreen.hub.viewInstead") { $0.requestScope(.view) }])
        case let .hubEnded(reason):
            title(reason.removesAccess ? L.t("macScreen.hub.revokedTitle", "Access Removed") : L.t("macScreen.card.endedTitle", "Disconnected"))
            detail(hostReason ?? reason.text(host: name))
            var row = [closeTab()]
            if reason.canReconnect {
                row.append(primary(L.t("macScreen.card.reconnect", "Reconnect"), hint: .return, id: "macScreen.card.reconnect") { $0.connect() })
            }
            buttons(row)
        default:
            break
        }
    }

    private func refusedContent(_ refusal: MacScreenHubRefusal, requested: SessionScope) {
        switch refusal {
        case .permissionNone:
            title(L.t("macScreen.hub.noneTitle", "No Access"))
            detail(String(format: L.t("macScreen.hub.noneBodyBlocked", "%1$@ doesn’t allow this Mac. Change it on %2$@ in Settings › Devices."), name, name))
            buttons([closeTab()])
        case .scopeExceeds:
            title(L.t("macScreen.hub.viewOnlyTitle", "View Only Access"))
            detail(String(format: L.t("macScreen.hub.viewOnlyBody", "This Mac may only view %@, not control it."), name))
            buttons([closeTab(), primary(L.t("macScreen.hub.viewInstead", "View Instead"), id: "macScreen.hub.viewInstead") { $0.requestScope(.view) }])
        case .hostOffline, .notShared, .notFound, .notSignedIn, .other:
            title(Self.refusedTitle(refusal, host: name))
            detail(Self.refusedBody(refusal, host: name, platform: model.platform))
            // Offline: Start cmux on NAME, the card's default button, on its own line (the card is too
            // narrow for three buttons), then the run's steps. Try Again steps down to a plain button.
            let setup = shown?.setup ?? .none
            if refusal == .hostOffline, setup.showsStart {
                startCmux(setup)
            }
            var row: [NSView] = [closeTab()]
            if refusal == .notSignedIn {
                // Not signed in: Sign In, the shared button every "sign in" place shows (msg 3790); Try Again
                // asks once more after it.
                row.append(MacScreenButton(L.t("macScreen.card.retry", "Try Again"), id: "macScreen.card.retry") { [weak self] in
                    self?.actions.requestScope(requested)
                })
                row.append(signInButton())
            } else if refusal.canRetry, refusal == .hostOffline, setup.showsStart {
                row.append(MacScreenButton(L.t("macScreen.card.retry", "Try Again"), id: "macScreen.card.retry") { [weak self] in
                    self?.actions.requestScope(requested)
                })
            } else if refusal.canRetry {
                row.append(primary(L.t("macScreen.card.retry", "Try Again"), id: "macScreen.card.retry") { $0.requestScope(requested) })
            }
            buttons(row)
        }
    }

    /// Start cmux on NAME (the daemon's `device-setup` start) and, once pressed, its steps.
    private func startCmux(_ setup: MacScreenDeviceSetupRow) {
        guard let id = model.hub?.deviceID else { return }
        let name = self.name, deviceSetup = model.deviceSetup
        let start = MacScreenButton(MacScreenSetupChecklist.startTitle(name), role: .primary, id: "macScreen.card.start") {
            deviceSetup?.run(.start, id: id, name: name)
        }
        start.isEnabled = setup.canRun(.start)
        stack.addArrangedSubview(start)
        if let run = setup.run {
            let list = MacScreenSetupChecklist.make(run, name: name, id: "macScreen.card.setupSteps") { deviceSetup?.dismiss(id: id) }
            stack.addArrangedSubview(list)
            list.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        }
    }

    /// The shared Sign In button (``SignInButton``): it starts the cmux sign-in.
    private func signInButton() -> SignInButton {
        let button = SignInButton { [weak self] in self?.actions.signIn() }
        button.setAccessibilityIdentifier("macScreen.card.signIn")
        return button
    }

    /// The refused card's title for `refusal` from `host`.
    static func refusedTitle(_ refusal: MacScreenHubRefusal, host name: String) -> String {
        switch refusal {
        case .hostOffline: String(format: L.t("macScreen.hub.offlineTitle", "%@ Is Offline"), name)
        case .notShared: L.t("macScreen.hub.notSharedTitle", "Not Shared")
        case .notFound: L.t("macScreen.hub.notFoundTitle", "Not in Your Devices")
        case .notSignedIn: L.t("macScreen.hub.signedOutTitle", "Not Signed In")
        case .permissionNone, .scopeExceeds, .other: L.t("macScreen.card.failedTitle", "Couldn’t connect")
        }
    }

    /// The refused card's text: a known code's own step, else the hub's words when it gave any.
    /// `platform` is the host's, when the hub lists it: a Linux desktop has no cmux app to open or Settings to change,
    /// so its offline and not-shared steps name its screen host instead.
    static func refusedBody(_ refusal: MacScreenHubRefusal, host name: String, platform: DevicePlatform? = nil) -> String {
        switch refusal {
        // Zero touch (remote-screen-share-zero-touch Z7): no state sends the person to the other machine. Its daemon
        // comes back on its own; the screen shows once it does.
        case .hostOffline: L.t("macScreen.hub.offlineBodyWaits", "Its screen shows here as soon as it is back online.")
        case .notShared where platform == .linux:
            String(format: L.t("macScreen.hub.notSharedBodyLinux", "%@ does not share its screen. To share it, run cmux-rd linux-host share on there."), name)
        case .notShared: String(format: L.t("macScreen.hub.notSharedBodyNamed", "%@ does not share its screen. To share it, turn on Allow Mac Screen in Settings › Devices on that Mac."), name)
        case .notFound: L.t("macScreen.hub.notFoundBody", "This device was removed from your devices.")
        case .notSignedIn: L.t("macScreen.hub.signedOutBody", "Sign in to cmux to see your devices.")
        case let .other(reason?):
            String(format: L.t("macScreen.hub.otherBodyReason", "The device hub could not start the session: %@"), reason)
        case .permissionNone, .scopeExceeds, .other: L.t("macScreen.hub.otherBody", "The device hub could not start the session. Try again.")
        }
    }

    /// Connect with View Only or Full Control; `primary` is the default button.
    private func scopeButtons(primary: SessionScope) {
        let view = MacScreenButton(L.t("macScreen.hub.view", "View Only"), role: primary == .view ? .primary : .plain,
                                   id: "macScreen.hub.connectView") { [weak self] in self?.actions.requestScope(.view) }
        let full = MacScreenButton(L.t("macScreen.hub.control", "Full Control"), role: primary == .full ? .primary : .plain, hint: .return,
                                   id: "macScreen.hub.connectFull") { [weak self] in self?.actions.requestScope(.full) }
        buttons([view, full])
    }
}
