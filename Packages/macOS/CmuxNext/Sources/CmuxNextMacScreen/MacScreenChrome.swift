import AppKit
import CmuxNextDesign
import CmuxNextDevices
import CmuxNextWakeups
import CmuxScreenKit
import Observation

/// A key combination for the Send Keys menu.
struct MacScreenShortcut: Identifiable {
    let id: String
    let title: String
    let key: VNCKeysym
    let modifiers: [VNCKeysym]

    /// Chords this Mac would take for itself, sent to the other Mac instead.
    static var all: [MacScreenShortcut] {
        [
            MacScreenShortcut(id: "spotlight", title: L.t("macScreen.keys.spotlight", "Spotlight (⌘Space)"),
                              key: .space, modifiers: [.command]),
            MacScreenShortcut(id: "switchApp", title: L.t("macScreen.keys.switchApp", "Switch App (⌘Tab)"),
                              key: .tab, modifiers: [.command]),
            MacScreenShortcut(id: "missionControl", title: L.t("macScreen.keys.missionControl", "Mission Control (⌃↑)"),
                              key: .up, modifiers: [.control]),
            MacScreenShortcut(id: "appWindows", title: L.t("macScreen.keys.appWindows", "App Windows (⌃↓)"),
                              key: .down, modifiers: [.control]),
            MacScreenShortcut(id: "quitApp", title: L.t("macScreen.keys.quitApp", "Quit App (⌘Q)"),
                              key: VNCKeysym(character: "q"), modifiers: [.command]),
            MacScreenShortcut(id: "closeWindow", title: L.t("macScreen.keys.closeWindow", "Close Window (⌘W)"),
                              key: VNCKeysym(character: "w"), modifiers: [.command]),
            MacScreenShortcut(id: "screenshot", title: L.t("macScreen.keys.screenshot", "Screenshot (⇧⌘5)"),
                              key: VNCKeysym(character: "5"), modifiers: [.shift, .command]),
            MacScreenShortcut(id: "forceQuit", title: L.t("macScreen.keys.forceQuit", "Force Quit (⌥⌘Esc)"),
                              key: .escape, modifiers: [.option, .command]),
            MacScreenShortcut(id: "lock", title: L.t("macScreen.keys.lock", "Lock Screen (⌃⌘Q)"),
                              key: VNCKeysym(character: "q"), modifiers: [.control, .command]),
        ]
    }
}

/// What the chrome's buttons do; the pane fills these in.
@MainActor
final class MacScreenChromeActions {
    var connect: () -> Void = {}
    var disconnect: () -> Void = {}
    var closeTab: () -> Void = {}
    var openHome: () -> Void = {}
    /// The card's Sign In: this Mac is not signed in to cmux (``MacScreenHubRefusal/notSignedIn``).
    var signIn: () -> Void = {}
    var selectDisplay: (Int) -> Void = { _ in }
    var setQuality: (ScreenQuality) -> Void = { _ in }
    var toggleStats: () -> Void = {}
    var refresh: () -> Void = {}
    var fullScreen: () -> Void = {}
    var sendKeys: (MacScreenShortcut) -> Void = { _ in }
    var focusScreen: () -> Void = {}
    /// A device hub tab: ask the host for a session of this scope.
    var requestScope: (SessionScope) -> Void = { _ in }
    /// A device hub tab: stop waiting for the host.
    var cancelRequest: () -> Void = {}
}

/// The card shown over the screen, if any.
enum MacScreenCard: Equatable {
    /// An old pairing-link record: link pairing is no longer supported.
    case unsupported
    case connecting(reconnecting: Bool)
    case waitingForPicture
    case failed
    case ended
    /// A device hub tab before a session: Connect with View Only or Full Control.
    case hubConnect
    /// The request is out, or approved and the ticket is coming.
    case hubRequesting(SessionScope)
    /// The host's person decides.
    case hubWaiting(SessionScope)
    case hubDeclined(SessionScope)
    case hubRefused(MacScreenHubRefusal, requested: SessionScope)
    case hubRevoked(MacScreenEndReason)
    /// A Full Control session ended because the host lowered this Mac's access to View Only.
    case hubAccessLowered
    case hubEnded(MacScreenEndReason)
}

/// The toolbar and the card over the screen, each in the tab's theme scope.
@MainActor
final class MacScreenChromeHost {
    let actions = MacScreenChromeActions()
    let toolbar: MacScreenToolbarView
    let card: MacScreenCardView
    private let model: MacScreenPaneModel

    init(model: MacScreenPaneModel) {
        self.model = model
        toolbar = MacScreenToolbarView(model: model, actions: actions)
        card = MacScreenCardView(model: model, actions: actions)
    }

    var showsCard: Bool { model.card != nil }
}

/// Holds the card's in-between states back until they last (Leo, 2026-11-14: "i also want all our
/// connectivity stuff to shut the f*** up and load faster"). Coming up (asking the hub, connecting,
/// waiting for the first picture) says nothing for ``ScreenSession/connectNoticeDelay`` (1 s, the
/// terminal's "Starting…" wait); Reconnecting says nothing for ``ScreenSession/reconnectNoticeDelay``
/// (10 s, every reconnect label in the app), over the last frame. A failure, an end, a refusal or a
/// card waiting on a person shows at once with its action. One ``QuietHold`` per kind of stretch.
@MainActor @Observable
final class MacScreenCardQuiet {
    /// Bumped when a hold ends: the card's observers read it and draw the card.
    private(set) var revealed = 0
    @ObservationIgnored private let comingUp: QuietHold
    @ObservationIgnored private let reconnecting: QuietHold

    init(clock: any Clock<Duration> = ContinuousClock()) {
        comingUp = QuietHold(owner: "mac-screen-card-connect", delay: ScreenSession.connectNoticeDelay, clock: clock)
        reconnecting = QuietHold(owner: "mac-screen-card-reconnect", delay: ScreenSession.reconnectNoticeDelay, clock: clock)
    }

    /// `card` as the screen shows it now: nil while its stretch is younger than its hold.
    func shown(_ card: MacScreenCard?) -> MacScreenCard? {
        _ = revealed
        let isComingUp = card.map(Self.comesUp) ?? false
        let isReconnecting = card == .connecting(reconnecting: true)
        comingUp.update(isComingUp) { [weak self] in self?.revealed &+= 1 }
        reconnecting.update(isReconnecting) { [weak self] in self?.revealed &+= 1 }
        if isComingUp, comingUp.held { return nil }
        if isReconnecting, reconnecting.held { return nil }
        return card
    }

    /// A card of a link coming up that usually ends on its own within a second.
    nonisolated static func comesUp(_ card: MacScreenCard) -> Bool {
        switch card {
        case .hubRequesting, .connecting(reconnecting: false), .waitingForPicture: true
        default: false
        }
    }
}

extension MacScreenPaneModel {
    /// The card on screen: ``liveCard`` with its in-between states held back (``MacScreenCardQuiet``).
    var card: MacScreenCard? { quiet.shown(liveCard) }

    /// The card the session's state calls for now, held or not: the screen takes input only without one.
    var liveCard: MacScreenCard? {
        switch gate {
        case .unsupported: return .unsupported
        case .open: break
        }
        if let hub, let card = Self.hubCard(hub.phase, access: hub.accessToHost) { return card }
        guard let session else { return .unsupported }
        switch session.phase {
        case .connecting: return Self.connectingCard(isReconnecting: session.isReconnecting, everConnected: everConnected)
        case .connected: return Self.connectedCard(hasFrame: hasFrame, stalled: session.isStalled)
        case .failed: return .failed
        case .ended: return .ended
        }
    }

    /// A device hub tab's card for `phase`; nil while it streams (the
    /// session's own phase decides then).
    static func hubCard(_ phase: MacScreenHubPhase, access: DeviceScope? = nil) -> MacScreenCard? {
        if case let .revoked(reason) = phase, MacScreenEndReason(reason) == .permissionRevoked {
            // The permission as it stands now: lowered to View, raised again, or None.
            switch access {
            case .view?: return .hubAccessLowered
            case .full?, .ask?: return .hubRevoked(.accessChanged)
            case .none?, nil: break
            }
        }
        switch phase {
        case .idle: return .hubConnect
        case let .requesting(scope), let .approved(_, scope): return .hubRequesting(scope)
        case let .waitingForApproval(_, scope): return .hubWaiting(scope)
        case .streaming, .streamFailed: return nil
        case let .declined(scope): return .hubDeclined(scope)
        case let .refused(refusal, requested): return .hubRefused(refusal, requested: requested)
        case let .revoked(reason): return .hubRevoked(MacScreenEndReason(reason))
        case let .ended(reason): return .hubEnded(MacScreenEndReason(reason))
        }
    }

    /// Why the stream failed, as the failed card says it: a TURN relay that
    /// refused the credentials or can't be reached, a relay-only path that
    /// found no relay, else what to check on the other Mac.
    var failedDetail: String {
        Self.failedDetail(relayErrors: session?.relayErrors ?? [], relayOnly: relayOnly, hubTab: hub != nil, name: name,
                          hubOnline: (hub?.hubConnected ?? true) && !(hub?.failedWhileOffline ?? false))
    }

    static func failedDetail(relayErrors errors: [ICECandidateError], relayOnly: Bool, hubTab: Bool, name: String,
                             hubOnline: Bool = true) -> String {
        if hubTab, !hubOnline {
            return L.t("macScreen.card.ownLinkLost", "This Mac lost its connection to the device hub. Check your network; cmux reconnects on its own.")
        }
        if errors.contains(where: \.refusedCredentials) {
            return L.t("macScreen.card.relayRefused", "The relay refused the credentials. Check its secret in Settings › Devices.")
        }
        if errors.contains(where: \.unreachable), relayOnly {
            return L.t("macScreen.card.relayUnreachable", "The relay can’t be reached. Check its URL and that its port is open.")
        }
        if relayOnly { return L.t("macScreen.card.relayNone", "No relay could connect the two Macs. Check your relays in Settings › Devices.") }
        return String(format: L.t("macScreen.card.failedHub", "Check that %@ is awake and online."), name)
    }

    /// Whether the toolbar shows the stream's controls: only while a session streams.
    var showsStreamControls: Bool {
        gate == .open && hub?.phase.streamingScope != nil
    }

    /// A connected session's card: none while the picture flows, Reconnecting
    /// once the connection stalls (shown past its hold, ``MacScreenCardQuiet``), Waiting
    /// until the first picture.
    static func connectedCard(hasFrame: Bool, stalled: Bool) -> MacScreenCard? {
        if stalled { return .connecting(reconnecting: true) }
        return hasFrame ? nil : .waitingForPicture
    }

    /// Every connect retries, so the reconnecting flag is set on a first
    /// connect too: the card says Reconnecting only once the Mac was shown.
    static func connectingCard(isReconnecting: Bool, everConnected: Bool) -> MacScreenCard {
        .connecting(reconnecting: isReconnecting && everConnected)
    }

    var isLive: Bool {
        guard gate == .open, let session else { return false }
        if case .connected = session.phase { return true }
        return false
    }
}
