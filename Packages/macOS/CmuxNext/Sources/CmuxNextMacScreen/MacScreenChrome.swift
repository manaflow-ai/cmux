import AppKit
import CmuxNextDesign
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
}

/// The card shown over the screen, if any.
enum MacScreenCard: Equatable {
    case confirm
    case missing
    case connecting(reconnecting: Bool)
    case waitingForPicture
    case failed
    case ended
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
        guard let session else { return .missing }
        switch session.phase {
        case .connecting: return Self.connectingCard(isReconnecting: session.isReconnecting, everConnected: everConnected)
        case .connected: return hasFrame ? nil : .waitingForPicture
        case .failed: return .failed
        case .ended: return .ended
        }
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
            if let session = model.session, model.gate == .open {
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
        .macScreenMenu(model.isLive ? colors.secondary : colors.tertiary)
        .disabled(!model.isLive)
        .themedHelp(L.t("macScreen.toolbar.sendKeys", "Send Keys"))
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
            detail(L.t("macScreen.card.failedHint", "Check that Share This Mac is on and the other Mac is awake."))
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
        }
    }
}
