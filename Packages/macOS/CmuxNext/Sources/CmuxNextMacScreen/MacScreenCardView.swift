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
    }

    static let width: CGFloat = 340
    /// The card's spinner: the side of a regular `ProgressView`.
    static let spinnerSide: CGFloat = 32
    private static let textWidth = width - 48

    private let model: MacScreenPaneModel
    private let actions: MacScreenChromeActions
    private let background = MacScreenFill(\.popup, shape: .rounded(Metrics.panelCornerRadius), bordered: true)
    private let stack = MacScreenStack.make(.vertical, spacing: 12, alignment: .centerX,
                                            insets: NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24))
    private(set) var shown: Shown?

    init(model: MacScreenPaneModel, actions: MacScreenChromeActions) {
        self.model = model
        self.actions = actions
        super.init(frame: .zero)
        setAccessibilityElement(false)
        background.setAccessibilityElement(true)
        background.setAccessibilityRole(.group)
        background.setAccessibilityIdentifier("macScreen.card")
        background.translatesAutoresizingMaskIntoConstraints = true
        background.autoresizingMask = [.width, .height]
        addSubview(background)
        background.addSubview(stack)
        // The card's frame comes from the pane (`fittingSize`): the far edges give way while it is not laid out yet.
        let trailing = stack.trailingAnchor.constraint(equalTo: background.trailingAnchor)
        let bottom = stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        trailing.priority = .init(999)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            trailing,
            bottom,
        ])
        render()
    }

    override var isFlipped: Bool { true }

    /// The card's size: its width, and the height of what it says at that width (zero with no card).
    override var fittingSize: NSSize {
        guard shown?.card != nil else { return .zero }
        return NSSize(width: Self.width, height: ceil(stack.fittingSize.height))
    }

    override func layout() {
        super.layout()
        background.frame = bounds
    }

    private func render() {
        let next = withObservationTracking {
            Shown(card: model.card, name: model.name, failedDetail: model.card == .failed ? model.failedDetail : "")
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.render() }
        }
        guard next != shown else { return }
        shown = next
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        background.isHidden = next.card == nil
        if let card = next.card { content(card) }
        paint(stack)
        // The pane centers the card at its new size.
        superview?.needsLayout = true
    }

    // MARK: Pieces

    private func title(_ text: String) {
        stack.addArrangedSubview(MacScreenText(text, font: MacScreenType.cardTitle, wraps: true, alignment: .center, width: Self.textWidth))
    }

    private func detail(_ text: String) {
        stack.addArrangedSubview(MacScreenText(text, font: MacScreenType.body, ink: \.secondary, wraps: true, alignment: .center,
                                               width: Self.textWidth))
    }

    private func glyph(_ name: String, ink: KeyPath<MacScreenColors, NSColor> = \.secondary) {
        let font = MacScreenType.glyph
        let glyph = MacScreenGlyph(name, font: font, ink: ink)
        // SwiftUI's `Image(systemName:).font(glyph)` took the font's line height, not the symbol's: the
        // card keeps the same room above its title.
        glyph.heightAnchor.constraint(equalToConstant: ceil(font.ascender - font.descender)).isActive = true
        stack.addArrangedSubview(glyph)
    }

    private func spinner() {
        let spinner = StatusIndicatorView.spinner()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: Self.spinnerSide),
            spinner.heightAnchor.constraint(equalToConstant: Self.spinnerSide),
        ])
        spinner.spin(true)
        stack.addArrangedSubview(spinner)
    }

    private func buttons(_ buttons: [MacScreenButton]) {
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

    private func content(_ card: MacScreenCard) {
        switch card {
        case .unsupported:
            glyph("link.badge.plus", ink: \.attention)
            title(L.t("macScreen.card.linksGoneTitle", "Pairing Links Are No Longer Supported"))
            detail(L.t("macScreen.card.linksGoneBody", "Mac Screen now connects the Macs signed in to your cmux account. Open Mac Screen to see them."))
            buttons([closeTab(id: "macScreen.card.closeTab"), primary(L.t("macScreen.card.openHome", "Open Mac Screen")) { $0.openHome() }])
        case let .connecting(reconnecting):
            spinner()
            title(reconnecting ? L.t("macScreen.card.reconnecting", "Reconnecting…")
                : String(format: L.t("macScreen.card.connecting", "Connecting to %@…"), name))
            buttons([cancel { $0.disconnect() }])
        case .waitingForPicture:
            spinner()
            title(L.t("macScreen.card.waiting", "Waiting for the screen…"))
        case .failed:
            // The session's message can quote the signaling URL (with the room id): never shown.
            glyph("exclamationmark.triangle", ink: \.attention)
            title(L.t("macScreen.card.failedTitle", "Couldn’t connect"))
            detail(shown?.failedDetail ?? model.failedDetail)
            buttons([closeTab(), primary(L.t("macScreen.card.retry", "Try Again"), hint: .return, id: "macScreen.card.retry") { $0.connect() }])
        case .ended:
            glyph("display")
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
            glyph("desktopcomputer")
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
            detail(String(format: L.t("macScreen.hub.waitingBody", "You asked for %@. Someone at that Mac needs to allow it."), scope.title))
            buttons([cancel({ $0.cancelRequest() }, id: "macScreen.hub.cancel")])
        case let .hubDeclined(scope):
            glyph("hand.raised", ink: \.attention)
            title(L.t("macScreen.hub.declinedTitle", "Declined"))
            detail(String(format: L.t("macScreen.hub.declinedBody", "%@ declined your request."), name))
            buttons([closeTab(), primary(L.t("macScreen.hub.askAgain", "Ask Again"), id: "macScreen.hub.askAgain") { $0.requestScope(scope) }])
        case let .hubRefused(refusal, requested):
            refusedContent(refusal, requested: requested)
        case let .hubRevoked(reason):
            // Ends from either side come as revocations too: only a lost permission or device reads as removed access.
            let removed = reason.removesAccess
            glyph(removed ? "lock" : "display", ink: removed ? \.danger : \.secondary)
            title(removed ? L.t("macScreen.hub.revokedTitle", "Access Removed") : L.t("macScreen.card.endedTitle", "Disconnected"))
            detail(reason.text(host: name))
            var row = [closeTab()]
            if reason.canReconnect {
                row.append(primary(L.t("macScreen.hub.connectAgain", "Connect Again"), id: "macScreen.hub.connectAgain") { $0.connect() })
            }
            buttons(row)
        case .hubAccessLowered:
            glyph("eye", ink: \.attention)
            title(L.t("macScreen.hub.loweredTitle", "Access Changed to View Only"))
            detail(String(format: L.t("macScreen.hub.loweredBody", "%@ now lets this Mac view its screen but not control it."), name))
            buttons([closeTab(), primary(L.t("macScreen.hub.viewInstead", "View Instead"), id: "macScreen.hub.viewInstead") { $0.requestScope(.view) }])
        case let .hubEnded(reason):
            glyph(reason.removesAccess ? "lock" : "display", ink: reason.removesAccess ? \.danger : \.secondary)
            title(reason.removesAccess ? L.t("macScreen.hub.revokedTitle", "Access Removed") : L.t("macScreen.card.endedTitle", "Disconnected"))
            detail(reason.text(host: name))
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
            glyph("nosign", ink: \.danger)
            title(L.t("macScreen.hub.noneTitle", "No Access"))
            detail(String(format: L.t("macScreen.hub.noneBodyBlocked", "%1$@ doesn’t allow this Mac. Change it on %2$@ in Settings › Devices."), name, name))
            buttons([closeTab()])
        case .scopeExceeds:
            glyph("eye", ink: \.attention)
            title(L.t("macScreen.hub.viewOnlyTitle", "View Only Access"))
            detail(String(format: L.t("macScreen.hub.viewOnlyBody", "This Mac may only view %@, not control it."), name))
            buttons([closeTab(), primary(L.t("macScreen.hub.viewInstead", "View Instead"), id: "macScreen.hub.viewInstead") { $0.requestScope(.view) }])
        case .hostOffline, .notShared, .notFound, .notSignedIn, .other:
            glyph(refusal == .hostOffline ? "wifi.slash" : "exclamationmark.triangle", ink: \.attention)
            title(refusedTitle(refusal))
            detail(refusedBody(refusal))
            var row = [closeTab()]
            if refusal.canRetry {
                row.append(primary(L.t("macScreen.card.retry", "Try Again"), id: "macScreen.card.retry") { $0.requestScope(requested) })
            }
            buttons(row)
        }
    }

    private func refusedTitle(_ refusal: MacScreenHubRefusal) -> String {
        switch refusal {
        case .hostOffline: String(format: L.t("macScreen.hub.offlineTitle", "%@ Is Offline"), name)
        case .notShared: L.t("macScreen.hub.notSharedTitle", "Not Shared")
        case .notFound: L.t("macScreen.hub.notFoundTitle", "Not in Your Devices")
        case .notSignedIn: L.t("macScreen.hub.signedOutTitle", "Not Signed In")
        case .permissionNone, .scopeExceeds, .other: L.t("macScreen.card.failedTitle", "Couldn’t connect")
        }
    }

    private func refusedBody(_ refusal: MacScreenHubRefusal) -> String {
        switch refusal {
        case .hostOffline: L.t("macScreen.hub.offlineBody", "Open cmux on that Mac and make sure it is signed in.")
        case .notShared: String(format: L.t("macScreen.hub.notSharedBodyNamed", "%@ does not share its screen. To share it, turn on Allow Mac Screen in Settings › Devices on that Mac."), name)
        case .notFound: L.t("macScreen.hub.notFoundBody", "This device was removed from your devices.")
        case .notSignedIn: L.t("macScreen.hub.signedOutBody", "Sign in to cmux to see your devices.")
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
