import AppKit
import CmuxNextDesign
import CmuxNextDevices

/// Look B of the viewer pane (`macScreen.viewerLook` = b), "Status strip" (ss-ui-spec (e) B): a fixed 28 pt strip at
/// window-chrome level above the picture that never overlays it and never hides. The strip carries the state ("Connecting
/// to studio-mini…", "Waiting for studio-mini to approve…", "Disconnected" with Reconnect) and the state's buttons, so the
/// body below is only the picture, Fit-letterboxed on the pane's ground (the window material, never black), or a calm
/// blank with one small mark. The strip's views are ``MacScreenStatusStripBar`` and ``MacScreenStatusStripBody``.
extension MacScreenViewerStyle {
    static var lookB: MacScreenViewerStyle {
        var style = MacScreenViewerStyle.current
        style.toolbarPlacement = .topBar
        style.statusStrip = true
        style.backdrop = .page
        style.pictureCornerRadius = 0
        style.pictureShadow = false
        return style
    }
}

/// Look B's two views: the strip on top and the body over the screen area while a state has no picture. The pane makes
/// them the first time a look with ``MacScreenViewerStyle/statusStrip`` is shown, so other looks pay nothing.
@MainActor
final class MacScreenStatusStrip {
    /// The strip's height: the design scale's row (28), at every pane width, so the picture and the pointer mapping never
    /// move when the pane resizes or the state changes.
    static let height: CGFloat = 28
    /// A transient state waits this long before it shows (arch: a blink of a state shows nothing).
    static let revealDelay: CFTimeInterval = 0.3
    /// A control in the strip: the design scale's compact control (24), centered in the row on the 4 pt grid.
    static let controlHeight: CGFloat = 24

    let bar: MacScreenStatusStripBar
    let body: MacScreenStatusStripBody

    init(model: MacScreenPaneModel, actions: MacScreenChromeActions, menus: MacScreenToolbarView) {
        bar = MacScreenStatusStripBar(model: model, actions: actions, menus: menus)
        body = MacScreenStatusStripBody(model: model, actions: actions)
    }
}

/// What the strip and the body say for one of the pane's cards: the card's own words, split so the title goes in the
/// strip with its buttons and the reason (if any) sits under the body's mark.
struct MacScreenStripState: Equatable {
    enum Mark: Equatable {
        /// A transient state: the shared loading mark, revealed after a short delay.
        case loading
        /// A lasting state: a small glyph in an ink.
        case glyph(String, KeyPath<MacScreenColors, NSColor>)
    }

    /// What a strip button does (the card's buttons, one for one).
    enum Run: Equatable {
        case closeTab
        case openHome
        case disconnect
        case cancelRequest
        case connect
        case request(SessionScope)
    }

    struct Action: Equatable {
        var title: String
        var run: Run
        var primary = false
        /// Return presses it (the card's default button).
        var returnKey = false
        var id: String?
    }

    var title: String
    /// The title's ink beside the machine's name: danger only for a failure or lost access, attention while someone must act.
    var ink: KeyPath<MacScreenColors, NSColor> = \.secondary
    var mark: Mark
    var caption: String?
    var actions: [Action] = []
    /// The body offers the shared Sign In button (this Mac is not signed in to cmux).
    var signIn = false

    /// The strip's state for `card`, in the card's words (``MacScreenCardView``).
    static func make(_ card: MacScreenCard, model: MacScreenPaneModel) -> MacScreenStripState {
        let name = model.name
        let closeTab = Action(title: L.t("macScreen.card.closeTab", "Close Tab"), run: .closeTab, id: "macScreen.card.closeTab")
        let cancel = Action(title: L.t("macScreen.card.cancel", "Cancel"), run: .disconnect)
        let reason = MacScreenCardView.failedDetail(card, model)
        switch card {
        case .unsupported:
            return MacScreenStripState(
                title: L.t("macScreen.card.linksGoneTitle", "Pairing Links Are No Longer Supported"), ink: \.attention,
                mark: .glyph("link.badge.plus", \.attention),
                caption: L.t("macScreen.card.linksGoneBody", "Screen Sharing now connects the Macs signed in to your cmux account. Open Screen Sharing to see them."),
                actions: [closeTab, Action(title: L.t("macScreen.card.openHome", "Open Screen Sharing"), run: .openHome, primary: true)])
        case let .connecting(reconnecting):
            return MacScreenStripState(
                title: reconnecting ? L.t("macScreen.card.reconnecting", "Reconnecting…") : String(format: L.t("macScreen.card.connecting", "Connecting to %@…"), name),
                mark: .loading, actions: [cancel])
        case .waitingForPicture:
            return MacScreenStripState(title: L.t("macScreen.card.waiting", "Waiting for the screen…"), mark: .loading, actions: [cancel])
        case .failed:
            return MacScreenStripState(
                title: L.t("macScreen.card.failedTitle", "Couldn’t connect"), ink: \.danger, mark: .glyph("exclamationmark.triangle", \.attention),
                caption: model.failedDetail,
                actions: [closeTab, Action(title: L.t("macScreen.card.retry", "Try Again"), run: .connect, primary: true, returnKey: true, id: "macScreen.card.retry")])
        case .ended:
            return MacScreenStripState(
                title: L.t("macScreen.card.endedTitle", "Disconnected"), mark: .glyph("display", \.secondary),
                actions: [closeTab, Action(title: L.t("macScreen.card.reconnect", "Reconnect"), run: .connect, primary: true, returnKey: true, id: "macScreen.card.reconnect")])
        case .hubConnect:
            return MacScreenStripState(
                title: String(format: L.t("macScreen.hub.connectTitle", "Connect to %@"), name), mark: .glyph("desktopcomputer", \.secondary),
                caption: L.t("macScreen.hub.connectBody", "View Only shows the screen. Full Control also sends your clicks and keys."),
                actions: [Action(title: L.t("macScreen.hub.view", "View Only"), run: .request(.view), id: "macScreen.hub.connectView"),
                          Action(title: L.t("macScreen.hub.control", "Full Control"), run: .request(.full), primary: true, returnKey: true, id: "macScreen.hub.connectFull")])
        case let .hubRequesting(scope):
            return MacScreenStripState(
                title: String(format: L.t("macScreen.hub.requesting", "Connecting to %@…"), name), mark: .loading, caption: scope.title,
                actions: [Action(title: L.t("macScreen.card.cancel", "Cancel"), run: .cancelRequest, id: "macScreen.hub.cancel")])
        case let .hubWaiting(scope):
            return MacScreenStripState(
                title: String(format: L.t("macScreen.hub.waitingTitle", "Waiting for %@ to approve…"), name), ink: \.attention, mark: .loading,
                caption: String(format: L.t("macScreen.hub.waitingOwnerBody", "You asked for %@. Its owner needs to allow it."), scope.title),
                actions: [Action(title: L.t("macScreen.card.cancel", "Cancel"), run: .cancelRequest, id: "macScreen.hub.cancel")])
        case let .hubDeclined(scope):
            return MacScreenStripState(
                title: L.t("macScreen.hub.declinedTitle", "Declined"), ink: \.attention, mark: .glyph("hand.raised", \.attention),
                caption: String(format: L.t("macScreen.hub.declinedBody", "%@ declined your request."), name),
                actions: [closeTab, Action(title: L.t("macScreen.hub.askAgain", "Ask Again"), run: .request(scope), primary: true, id: "macScreen.hub.askAgain")])
        case let .hubRefused(refusal, requested):
            return refused(refusal, requested: requested, model: model, closeTab: closeTab)
        case let .hubRevoked(endReason), let .hubEnded(endReason):
            let removed = endReason.removesAccess
            var actions = [closeTab]
            if endReason.canReconnect, case .hubRevoked = card {
                actions.append(Action(title: L.t("macScreen.hub.connectAgain", "Connect Again"), run: .connect, primary: true, id: "macScreen.hub.connectAgain"))
            } else if endReason.canReconnect {
                actions.append(Action(title: L.t("macScreen.card.reconnect", "Reconnect"), run: .connect, primary: true, returnKey: true,
                                      id: "macScreen.card.reconnect"))
            }
            return MacScreenStripState(
                title: removed ? L.t("macScreen.hub.revokedTitle", "Access Removed") : L.t("macScreen.card.endedTitle", "Disconnected"),
                ink: removed ? \.danger : \.secondary, mark: .glyph(removed ? "lock" : "display", removed ? \.danger : \.secondary),
                caption: reason.isEmpty ? endReason.text(host: name) : reason, actions: actions)
        case .hubAccessLowered:
            return MacScreenStripState(
                title: L.t("macScreen.hub.loweredTitle", "Access Changed to View Only"), ink: \.attention, mark: .glyph("eye", \.attention),
                caption: String(format: L.t("macScreen.hub.loweredBody", "%@ now lets this Mac view its screen but not control it."), name),
                actions: [closeTab, Action(title: L.t("macScreen.hub.viewInstead", "View Instead"), run: .request(.view), primary: true, id: "macScreen.hub.viewInstead")])
        }
    }

    private static func refused(_ refusal: MacScreenHubRefusal, requested: SessionScope, model: MacScreenPaneModel, closeTab: Action) -> MacScreenStripState {
        let name = model.name
        switch refusal {
        case .permissionNone:
            return MacScreenStripState(
                title: L.t("macScreen.hub.noneTitle", "No Access"), ink: \.danger, mark: .glyph("nosign", \.danger),
                caption: String(format: L.t("macScreen.hub.noneBodyBlocked", "%1$@ doesn’t allow this Mac. Change it on %2$@ in Settings › Devices."), name, name),
                actions: [closeTab])
        case .scopeExceeds:
            return MacScreenStripState(
                title: L.t("macScreen.hub.viewOnlyTitle", "View Only Access"), ink: \.attention, mark: .glyph("eye", \.attention),
                caption: String(format: L.t("macScreen.hub.viewOnlyBody", "This Mac may only view %@, not control it."), name),
                actions: [closeTab, Action(title: L.t("macScreen.hub.viewInstead", "View Instead"), run: .request(.view), primary: true, id: "macScreen.hub.viewInstead")])
        case .hostOffline, .notShared, .notFound, .notSignedIn, .other:
            var actions = [closeTab]
            if refusal == .notSignedIn || refusal.canRetry {
                // Not signed in: Try Again stays plain, the body offers the shared Sign In button.
                actions.append(Action(title: L.t("macScreen.card.retry", "Try Again"), run: .request(requested), primary: refusal != .notSignedIn,
                                      id: "macScreen.card.retry"))
            }
            return MacScreenStripState(
                title: MacScreenCardView.refusedTitle(refusal, host: name), ink: \.attention,
                mark: .glyph(refusal == .hostOffline ? "wifi.slash" : "exclamationmark.triangle", \.attention),
                caption: MacScreenCardView.refusedBody(refusal, host: name, platform: model.platform), actions: actions,
                signIn: refusal == .notSignedIn)
        }
    }
}

extension MacScreenChromeActions {
    /// Runs a strip button's action.
    func run(_ run: MacScreenStripState.Run) {
        switch run {
        case .closeTab: closeTab()
        case .openHome: openHome()
        case .disconnect: disconnect()
        case .cancelRequest: cancelRequest()
        case .connect: connect()
        case let .request(scope): requestScope(scope)
        }
    }
}

extension MacScreenChromeHost {
    /// Lays look B's strip out in `pane` (made and added, after the picture, the first time a look asks for it); the
    /// toolbar takes the look's own visibility (``MacScreenToolbarView/hiddenByLook``: hidden under the strip, a pill off a
    /// live picture, a faded auto-hide). Returns whether the pane shows its state card: never under the strip.
    func layoutStatusStrip(_ style: MacScreenViewerStyle, in pane: MacScreenPaneView) -> Bool {
        toolbar.syncHidden()
        guard style.statusStrip else {
            statusStrip?.bar.isHidden = true
            statusStrip?.body.isHidden = true
            return showsCard
        }
        let strip: MacScreenStatusStrip
        if let statusStrip {
            strip = statusStrip
        } else {
            strip = MacScreenStatusStrip(model: model, actions: actions, menus: toolbar)
            statusStrip = strip
            pane.addSubview(strip.body)
            pane.addSubview(strip.bar)
        }
        strip.bar.isHidden = false
        strip.bar.frame = CGRect(x: 0, y: 0, width: pane.bounds.width, height: MacScreenStatusStrip.height)
        // An outage keeps the last frame up (arch D12): the strip says Reconnecting, the body never covers the picture.
        let keepsPicture = model.card == .connecting(reconnecting: true) && !pane.video.frame.isEmpty
        strip.body.isHidden = model.card == nil || keepsPicture
        strip.body.frame = pane.screenRect
        return false
    }
}
