import AppKit
import CmuxNextDesign
import CmuxNextDevices
import CmuxScreenKit
import Observation
import SwiftUI

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
    var confirm: () -> Void = {}
    var closeTab: () -> Void = {}
    var openHome: () -> Void = {}
    var selectDisplay: (Int) -> Void = { _ in }
    var setQuality: (ScreenQuality) -> Void = { _ in }
    var toggleStats: () -> Void = {}
    var refresh: () -> Void = {}
    var sendKeys: (MacScreenShortcut) -> Void = { _ in }
    var focusScreen: () -> Void = {}
    /// A device hub tab: ask the host for a session of this scope.
    var requestScope: (SessionScope) -> Void = { _ in }
    /// A device hub tab: stop waiting for the host.
    var cancelRequest: () -> Void = {}
}

/// The card shown over the screen, if any.
enum MacScreenCard: Equatable {
    case confirm
    case missing
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

/// The toolbar and card hosting views, each in the tab's theme scope.
@MainActor
final class MacScreenChromeHost {
    let actions = MacScreenChromeActions()
    let toolbar: MacScreenHostingView<MacScreenToolbar>
    let card: MacScreenHostingView<MacScreenCardView>
    private let model: MacScreenPaneModel

    init(model: MacScreenPaneModel) {
        self.model = model
        toolbar = MacScreenHostingView(MacScreenToolbar(model: model, actions: actions))
        card = MacScreenHostingView(MacScreenCardView(model: model, actions: actions))
        toolbar.sizingOptions = []
        card.sizingOptions = [.intrinsicContentSize]
    }

    var showsCard: Bool { model.card != nil }
}

extension MacScreenPaneModel {
    var card: MacScreenCard? {
        switch gate {
        case .confirm: return .confirm
        case .missing: return .missing
        case .open: break
        }
        if let hub, let card = Self.hubCard(hub.phase, access: hub.accessToHost) { return card }
        guard let session else { return .missing }
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
        if hubTab { return String(format: L.t("macScreen.card.failedHub", "Check that %@ is awake and online."), name) }
        return L.t("macScreen.card.failedHint", "Check that Share This Mac is on and the other Mac is awake.")
    }

    /// Whether the toolbar shows the stream's controls: a link-paired Mac's
    /// always, a device hub tab's only while a session streams.
    var showsStreamControls: Bool {
        guard gate == .open else { return false }
        guard let hub else { return true }
        return hub.phase.streamingScope != nil
    }

    /// A connected session's card: none while the picture flows, Reconnecting
    /// as soon as the connection stalls (never a frozen picture), Waiting
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

struct MacScreenToolbar: View {
    let model: MacScreenPaneModel
    let actions: MacScreenChromeActions
    @Environment(\.macScreenColors) private var colors

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            // In a narrow pane the controls keep their size. The stats and the
            // release hint show whole or not at all, then the icon goes, so the
            // name keeps the room that is left.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").foregroundStyle(colors.secondary)
                    name
                }
                name
            }
            .layoutPriority(1)
            if let session = model.session, model.isLive, session.preferences.showStats {
                ViewThatFits(in: .horizontal) {
                    Text(statsLine(session)).font(MacScreenType.stats).foregroundStyle(colors.secondary).lineLimit(1)
                        .fixedSize()
                        .accessibilityIdentifier("macScreen.stats")
                    Color.clear.frame(width: 0, height: 0)
                }
                .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if model.viewOnly {
                Label(L.t("macScreen.toolbar.viewOnly", "View Only"), systemImage: "eye")
                    .font(MacScreenType.caption.weight(.semibold)).foregroundStyle(colors.attention).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(colors.attention.opacity(0.14), in: Capsule())
                    .fixedSize()
                    .layoutPriority(3)
                    .themedHelp(String(format: L.t("macScreen.toolbar.viewOnlyHelpNamed", "You can see %@ but not control it. Your clicks, keys and scrolling aren’t sent."), model.name))
                    .accessibilityIdentifier("macScreen.viewOnly")
            }
            if model.capturesKeyboard, model.isLive {
                ViewThatFits(in: .horizontal) {
                    Label(L.t("macScreen.toolbar.releaseHint", "⌃⌥⎋ releases the keyboard"), systemImage: "keyboard")
                        .font(MacScreenType.caption).foregroundStyle(colors.secondary).lineLimit(1)
                        .fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                .layoutPriority(-2)
                .themedHelp(L.t("macScreen.toolbar.keyboardHint", "Keyboard goes to this Mac · ⌃⌥⎋ to release"))
            }
            if let session = model.session, model.showsStreamControls {
                HStack(spacing: 10) { controls(session) }
                    .fixedSize()
                    .layoutPriority(2)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.chrome)
        .overlay(alignment: .bottom) {
            if colors.borders { colors.separator.frame(height: 1) }
        }
    }

    private var name: some View {
        Text(model.name).font(MacScreenType.emphasized).foregroundStyle(colors.primary).lineLimit(1)
            .frame(minWidth: 24, alignment: .leading)
    }

    @ViewBuilder
    private func controls(_ session: ScreenSession) -> some View {
        if model.displays.count > 1 {
            Menu {
                ForEach(Array(model.displays.enumerated()), id: \.offset) { index, size in
                    Toggle(isOn: Binding(get: { model.currentDisplay == index }, set: { _ in actions.selectDisplay(index) })) {
                        Text(String(format: L.t("macScreen.toolbar.display", "Display %d (%d × %d)"), index + 1, Int(size.width), Int(size.height)))
                    }
                }
            } label: {
                Label(String(format: L.t("macScreen.toolbar.displayShort", "Display %d"), model.currentDisplay + 1), systemImage: "display.2")
                    .font(MacScreenType.body)
            }
            .macScreenMenu(colors.secondary)
            .accessibilityIdentifier("macScreen.display")
        }
        Menu {
            Picker(L.t("macScreen.toolbar.quality", "Quality"), selection: Binding(get: { session.preferences.quality }, set: { actions.setQuality($0) })) {
                ForEach(ScreenQuality.allCases) { quality in Text(qualityTitle(quality)).tag(quality) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(L.t("macScreen.toolbar.showStats", "Show Stats"), isOn: Binding(get: { session.preferences.showStats }, set: { _ in actions.toggleStats() }))
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .macScreenMenu(colors.secondary)
        .themedHelp(L.t("macScreen.toolbar.qualityHelp", "Quality and stats"))
        .accessibilityIdentifier("macScreen.quality")
        Menu {
            if let shortcuts = model.systemShortcuts {
                // The setting (macScreen.systemShortcuts): every Mac Screen tab follows it.
                Toggle(L.t("macScreen.keys.systemShortcuts", "Send System Shortcuts to the Remote Mac"),
                       isOn: Binding(get: { shortcuts.enabled }, set: { shortcuts.setEnabled($0) }))
                if shortcuts.needsAccessibility {
                    Button(L.t("macScreen.keys.allowAccessibility", "Allow Accessibility for System Shortcuts…")) {
                        shortcuts.requestAccessibility()
                    }
                }
                Divider()
            }
            ForEach(MacScreenShortcut.all) { shortcut in
                Button(shortcut.title) { actions.sendKeys(shortcut) }
            }
        } label: {
            Image(systemName: "command")
        }
        .macScreenMenu(model.isLive && !model.viewOnly ? colors.secondary : colors.tertiary)
        .disabled(!model.isLive || model.viewOnly)
        .themedHelp(model.viewOnly ? L.t("macScreen.toolbar.sendKeysViewOnly", "Send Keys is off in a View Only session")
            : L.t("macScreen.toolbar.sendKeys", "Send Keys"))
        .accessibilityIdentifier("macScreen.sendKeys")
        Button(action: actions.refresh) { Image(systemName: "arrow.clockwise") }
            .buttonStyle(MacScreenButtonStyle(role: .icon)).disabled(!model.isLive)
            .themedHelp(L.t("macScreen.toolbar.refresh", "Refresh Screen"))
        switch session.phase {
        case .ended, .failed:
            Button(L.t("macScreen.toolbar.connect", "Connect"), action: actions.connect)
                .buttonStyle(MacScreenButtonStyle(role: .primary, compact: true))
                .accessibilityIdentifier("macScreen.connect")
        default:
            Button(L.t("macScreen.toolbar.disconnect", "Disconnect"), action: actions.disconnect)
                .buttonStyle(MacScreenButtonStyle(compact: true))
                .accessibilityIdentifier("macScreen.disconnect")
        }
    }

    private var statusColor: Color {
        if let hub = model.hub {
            switch hub.phase {
            case .requesting, .waitingForApproval, .approved: return colors.attention
            case .declined, .refused, .revoked: return colors.danger
            case .idle, .ended: return colors.tertiary
            case .streaming, .streamFailed: break
            }
        }
        guard model.gate == .open, let session = model.session else { return colors.tertiary }
        switch session.phase {
        case .connected: return session.isReconnecting ? colors.attention : colors.success
        case .connecting: return colors.attention
        case .failed: return colors.danger
        case .ended: return colors.tertiary
        }
    }

    private func statsLine(_ session: ScreenSession) -> String {
        let stats = session.stats
        var parts = [session.streamPath, String(format: "%.0f fps", stats.fps)]
        if let rtt = stats.latencyMs { parts.append(String(format: "%.0f ms", rtt)) }
        if stats.encoding != "-" { parts.append(stats.encoding) }
        if session.frameSize.width >= 1 { parts.append("\(Int(session.frameSize.width))×\(Int(session.frameSize.height))") }
        return parts.joined(separator: " · ")
    }

    private func qualityTitle(_ quality: ScreenQuality) -> String {
        switch quality {
        case .auto: L.t("macScreen.quality.auto", "Auto")
        case .smooth: L.t("macScreen.quality.smooth", "Smooth Motion")
        case .low: L.t("macScreen.quality.low", "Fixed Low (720p)")
        case .medium: L.t("macScreen.quality.medium", "Fixed Medium (1080p)")
        case .high: L.t("macScreen.quality.high", "Fixed High (Full)")
        }
    }
}

struct MacScreenCardView: View {
    let model: MacScreenPaneModel
    let actions: MacScreenChromeActions
    @Environment(\.macScreenColors) private var colors

    var body: some View {
        if let card = model.card {
            VStack(spacing: 12) {
                content(card)
            }
            .foregroundStyle(colors.primary)
            .font(MacScreenType.body)
            .padding(24)
            .frame(width: 340)
            .background(colors.popup, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius, style: .continuous))
            .overlay {
                if colors.borders {
                    RoundedRectangle(cornerRadius: Metrics.panelCornerRadius, style: .continuous).strokeBorder(colors.separator)
                }
            }
            .accessibilityIdentifier("macScreen.card")
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(MacScreenType.subtitle.weight(.semibold)).multilineTextAlignment(.center)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(MacScreenType.body).multilineTextAlignment(.center).foregroundStyle(colors.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func glyph(_ name: String, color: Color? = nil) -> some View {
        Image(systemName: name).font(MacScreenType.glyph).foregroundStyle(color ?? colors.secondary)
    }

    @ViewBuilder
    private func content(_ card: MacScreenCard) -> some View {
        switch card {
        case .confirm:
            glyph("desktopcomputer")
            title(String(format: L.t("macScreen.card.confirmTitle", "Show %@?"), model.name))
            detail(L.t("macScreen.card.confirmBody", "This tab was opened for you. Connect to see and control this Mac."))
            Button(L.t("macScreen.card.connect", "Connect"), action: actions.confirm)
                .buttonStyle(MacScreenButtonStyle(role: .primary))
                .accessibilityIdentifier("macScreen.card.confirm")
        case .missing:
            glyph("questionmark.square.dashed")
            title(L.t("macScreen.card.missingTitle", "This Mac is not paired"))
            detail(L.t("macScreen.card.missingBody", "It was forgotten, or this tab came from another Mac. Pair it again from Mac Screen."))
            Button(L.t("macScreen.card.openHome", "Open Mac Screen"), action: actions.openHome)
                .buttonStyle(MacScreenButtonStyle())
        case let .connecting(reconnecting):
            ProgressView().controlSize(.regular)
            title(reconnecting ? L.t("macScreen.card.reconnecting", "Reconnecting…")
                : String(format: L.t("macScreen.card.connecting", "Connecting to %@…"), model.name))
            Button(L.t("macScreen.card.cancel", "Cancel"), action: actions.disconnect)
                .buttonStyle(MacScreenButtonStyle())
        case .waitingForPicture:
            ProgressView().controlSize(.regular)
            title(L.t("macScreen.card.waiting", "Waiting for the screen…"))
        case .failed:
            // The session's message can quote the signaling URL (with the room id): never shown.
            glyph("exclamationmark.triangle", color: colors.attention)
            title(L.t("macScreen.card.failedTitle", "Couldn’t connect"))
            detail(model.failedDetail)
            HStack {
                Button(L.t("macScreen.card.closeTab", "Close Tab"), action: actions.closeTab)
                    .buttonStyle(MacScreenButtonStyle())
                Button(L.t("macScreen.card.retry", "Try Again"), action: actions.connect).keyboardShortcut(.defaultAction)
                    .buttonStyle(MacScreenButtonStyle(role: .primary))
                    .accessibilityIdentifier("macScreen.card.retry")
            }
        case .ended:
            glyph("display")
            title(L.t("macScreen.card.endedTitle", "Disconnected"))
            HStack {
                Button(L.t("macScreen.card.closeTab", "Close Tab"), action: actions.closeTab)
                    .buttonStyle(MacScreenButtonStyle())
                Button(L.t("macScreen.card.reconnect", "Reconnect"), action: actions.connect).keyboardShortcut(.defaultAction)
                    .buttonStyle(MacScreenButtonStyle(role: .primary))
                    .accessibilityIdentifier("macScreen.card.reconnect")
            }
        case .hubConnect, .hubRequesting, .hubWaiting, .hubDeclined, .hubRefused, .hubRevoked, .hubAccessLowered, .hubEnded:
            hubContent(card)
        }
    }

    /// A device hub tab's cards: Connect, waiting, and every way a request or session ends.
    @ViewBuilder
    private func hubContent(_ card: MacScreenCard) -> some View {
        switch card {
        case .hubConnect:
            glyph("desktopcomputer")
            title(String(format: L.t("macScreen.hub.connectTitle", "Connect to %@"), model.name))
            detail(L.t("macScreen.hub.connectBody", "View Only shows the screen. Full Control also sends your clicks and keys."))
            scopeButtons(primary: .full)
        case let .hubRequesting(scope):
            ProgressView().controlSize(.regular)
            title(String(format: L.t("macScreen.hub.requesting", "Connecting to %@…"), model.name))
            detail(scope.title)
            Button(L.t("macScreen.card.cancel", "Cancel"), action: actions.cancelRequest)
                .buttonStyle(MacScreenButtonStyle())
                .accessibilityIdentifier("macScreen.hub.cancel")
        case let .hubWaiting(scope):
            ProgressView().controlSize(.regular)
            title(String(format: L.t("macScreen.hub.waitingTitle", "Waiting for %@ to approve…"), model.name))
            detail(String(format: L.t("macScreen.hub.waitingBody", "You asked for %@. Someone at that Mac needs to allow it."), scope.title))
            Button(L.t("macScreen.card.cancel", "Cancel"), action: actions.cancelRequest)
                .buttonStyle(MacScreenButtonStyle())
                .accessibilityIdentifier("macScreen.hub.cancel")
        case let .hubDeclined(scope):
            glyph("hand.raised", color: colors.attention)
            title(L.t("macScreen.hub.declinedTitle", "Declined"))
            detail(String(format: L.t("macScreen.hub.declinedBody", "%@ declined your request."), model.name))
            HStack {
                Button(L.t("macScreen.card.closeTab", "Close Tab"), action: actions.closeTab)
                    .buttonStyle(MacScreenButtonStyle())
                Button(L.t("macScreen.hub.askAgain", "Ask Again")) { actions.requestScope(scope) }
                    .buttonStyle(MacScreenButtonStyle(role: .primary))
                    .accessibilityIdentifier("macScreen.hub.askAgain")
            }
        case let .hubRefused(refusal, requested):
            refusedContent(refusal, requested: requested)
        case let .hubRevoked(reason):
            // Ends from either side come as revocations too: only a lost permission or device reads as removed access.
            let removed = reason.removesAccess
            glyph(removed ? "lock" : "display", color: removed ? colors.danger : nil)
            title(removed ? L.t("macScreen.hub.revokedTitle", "Access Removed") : L.t("macScreen.card.endedTitle", "Disconnected"))
            detail(reason.text(host: model.name))
            HStack {
                Button(L.t("macScreen.card.closeTab", "Close Tab"), action: actions.closeTab)
                    .buttonStyle(MacScreenButtonStyle())
                if reason.canReconnect {
                    Button(L.t("macScreen.hub.connectAgain", "Connect Again"), action: actions.connect)
                        .buttonStyle(MacScreenButtonStyle(role: .primary))
                        .accessibilityIdentifier("macScreen.hub.connectAgain")
                }
            }
        case .hubAccessLowered:
            glyph("eye", color: colors.attention)
            title(L.t("macScreen.hub.loweredTitle", "Access Changed to View Only"))
            detail(String(format: L.t("macScreen.hub.loweredBody", "%@ now lets this Mac view its screen but not control it."), model.name))
            HStack {
                Button(L.t("macScreen.card.closeTab", "Close Tab"), action: actions.closeTab)
                    .buttonStyle(MacScreenButtonStyle())
                Button(L.t("macScreen.hub.viewInstead", "View Instead")) { actions.requestScope(.view) }
                    .buttonStyle(MacScreenButtonStyle(role: .primary))
                    .accessibilityIdentifier("macScreen.hub.viewInstead")
            }
        case let .hubEnded(reason):
            glyph(reason.removesAccess ? "lock" : "display", color: reason.removesAccess ? colors.danger : nil)
            title(reason.removesAccess ? L.t("macScreen.hub.revokedTitle", "Access Removed") : L.t("macScreen.card.endedTitle", "Disconnected"))
            detail(reason.text(host: model.name))
            HStack {
                Button(L.t("macScreen.card.closeTab", "Close Tab"), action: actions.closeTab)
                    .buttonStyle(MacScreenButtonStyle())
                if reason.canReconnect {
                    Button(L.t("macScreen.card.reconnect", "Reconnect"), action: actions.connect).keyboardShortcut(.defaultAction)
                        .buttonStyle(MacScreenButtonStyle(role: .primary))
                        .accessibilityIdentifier("macScreen.card.reconnect")
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func refusedContent(_ refusal: MacScreenHubRefusal, requested: SessionScope) -> some View {
        switch refusal {
        case .permissionNone:
            glyph("nosign", color: colors.danger)
            title(L.t("macScreen.hub.noneTitle", "No Access"))
            detail(String(format: L.t("macScreen.hub.noneBodyBlocked", "%1$@ doesn’t allow this Mac. Change it on %2$@ in Settings › Devices."), model.name, model.name))
            Button(L.t("macScreen.card.closeTab", "Close Tab"), action: actions.closeTab)
                .buttonStyle(MacScreenButtonStyle())
        case .scopeExceeds:
            glyph("eye", color: colors.attention)
            title(L.t("macScreen.hub.viewOnlyTitle", "View Only Access"))
            detail(String(format: L.t("macScreen.hub.viewOnlyBody", "This Mac may only view %@, not control it."), model.name))
            HStack {
                Button(L.t("macScreen.card.closeTab", "Close Tab"), action: actions.closeTab)
                    .buttonStyle(MacScreenButtonStyle())
                Button(L.t("macScreen.hub.viewInstead", "View Instead")) { actions.requestScope(.view) }
                    .buttonStyle(MacScreenButtonStyle(role: .primary))
                    .accessibilityIdentifier("macScreen.hub.viewInstead")
            }
        case .hostOffline, .notShared, .notFound, .notSignedIn, .other:
            glyph(refusal == .hostOffline ? "wifi.slash" : "exclamationmark.triangle", color: colors.attention)
            title(refusedTitle(refusal))
            detail(refusedBody(refusal))
            HStack {
                Button(L.t("macScreen.card.closeTab", "Close Tab"), action: actions.closeTab)
                    .buttonStyle(MacScreenButtonStyle())
                if refusal.canRetry {
                    Button(L.t("macScreen.card.retry", "Try Again")) { actions.requestScope(requested) }
                        .buttonStyle(MacScreenButtonStyle(role: .primary))
                        .accessibilityIdentifier("macScreen.card.retry")
                }
            }
        }
    }

    private func refusedTitle(_ refusal: MacScreenHubRefusal) -> String {
        switch refusal {
        case .hostOffline: String(format: L.t("macScreen.hub.offlineTitle", "%@ Is Offline"), model.name)
        case .notShared: L.t("macScreen.hub.notSharedTitle", "Not Shared")
        case .notFound: L.t("macScreen.hub.notFoundTitle", "Not in Your Devices")
        case .notSignedIn: L.t("macScreen.hub.signedOutTitle", "Not Signed In")
        case .permissionNone, .scopeExceeds, .other: L.t("macScreen.card.failedTitle", "Couldn’t connect")
        }
    }

    private func refusedBody(_ refusal: MacScreenHubRefusal) -> String {
        switch refusal {
        case .hostOffline: L.t("macScreen.hub.offlineBody", "Open cmux on that Mac and make sure it is signed in.")
        case .notShared: String(format: L.t("macScreen.hub.notSharedBodyNamed", "%@ does not share its screen. To share it, turn on Allow Mac Screen in Settings › Devices on that Mac."), model.name)
        case .notFound: L.t("macScreen.hub.notFoundBody", "This device was removed from your devices.")
        case .notSignedIn: L.t("macScreen.hub.signedOutBody", "Sign in to cmux to see your devices.")
        case .permissionNone, .scopeExceeds, .other: L.t("macScreen.hub.otherBody", "The device hub could not start the session. Try again.")
        }
    }

    /// Connect with View Only or Full Control; `primary` is the default button.
    private func scopeButtons(primary: SessionScope) -> some View {
        HStack {
            Button(L.t("macScreen.hub.view", "View Only")) { actions.requestScope(.view) }
                .buttonStyle(MacScreenButtonStyle(role: primary == .view ? .primary : .plain))
                .accessibilityIdentifier("macScreen.hub.connectView")
            Button(L.t("macScreen.hub.control", "Full Control")) { actions.requestScope(.full) }
                .buttonStyle(MacScreenButtonStyle(role: primary == .full ? .primary : .plain))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("macScreen.hub.connectFull")
        }
    }
}
