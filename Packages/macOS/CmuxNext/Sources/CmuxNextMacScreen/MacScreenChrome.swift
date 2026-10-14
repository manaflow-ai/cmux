import AppKit
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

/// The toolbar and card hosting views.
@MainActor
final class MacScreenChromeHost {
    let actions = MacScreenChromeActions()
    let toolbar: NSHostingView<MacScreenToolbar>
    let card: NSHostingView<MacScreenCardView>
    private let model: MacScreenPaneModel

    init(model: MacScreenPaneModel) {
        self.model = model
        toolbar = NSHostingView(rootView: MacScreenToolbar(model: model, actions: actions))
        card = NSHostingView(rootView: MacScreenCardView(model: model, actions: actions))
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
        case .connecting: return .connecting(reconnecting: session.isReconnecting)
        case .connected: return hasFrame ? nil : .waitingForPicture
        case .failed: return .failed
        case .ended: return .ended
        }
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

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            // In a narrow pane the controls keep their size; the stats, then
            // the release hint, give way before the name.
            Text(model.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .layoutPriority(1)
            if let session = model.session, model.isLive, session.preferences.showStats {
                Text(statsLine(session)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    .layoutPriority(-1)
                    .accessibilityIdentifier("macScreen.stats")
            }
            Spacer(minLength: 8)
            if model.capturesKeyboard, model.isLive {
                Label(L.t("macScreen.toolbar.releaseHint", "⌃⌥⎋ releases the keyboard"), systemImage: "keyboard")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .layoutPriority(-2)
                    .help(L.t("macScreen.toolbar.keyboardHint", "Keyboard goes to this Mac · ⌃⌥⎋ to release"))
            }
            if let session = model.session, model.gate == .open {
                HStack(spacing: 10) { controls(session) }
                    .fixedSize()
                    .layoutPriority(2)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
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
            }
            .menuStyle(.borderlessButton).fixedSize()
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
        .menuStyle(.borderlessButton).fixedSize()
        .help(L.t("macScreen.toolbar.qualityHelp", "Quality and stats"))
        .accessibilityIdentifier("macScreen.quality")
        Menu {
            ForEach(MacScreenShortcut.all) { shortcut in
                Button(shortcut.title) { actions.sendKeys(shortcut) }
            }
        } label: {
            Image(systemName: "command")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(!model.isLive)
        .help(L.t("macScreen.toolbar.sendKeys", "Send Keys"))
        .accessibilityIdentifier("macScreen.sendKeys")
        Button(action: actions.refresh) { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.borderless).disabled(!model.isLive)
            .help(L.t("macScreen.toolbar.refresh", "Refresh Screen"))
        switch session.phase {
        case .ended, .failed:
            Button(L.t("macScreen.toolbar.connect", "Connect"), action: actions.connect).controlSize(.small)
                .accessibilityIdentifier("macScreen.connect")
        default:
            Button(L.t("macScreen.toolbar.disconnect", "Disconnect"), action: actions.disconnect).controlSize(.small)
                .accessibilityIdentifier("macScreen.disconnect")
        }
    }

    private var statusColor: Color {
        guard model.gate == .open, let session = model.session else { return .gray }
        switch session.phase {
        case .connected: return session.isReconnecting ? .orange : .green
        case .connecting: return .orange
        case .failed: return .red
        case .ended: return .gray
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

    var body: some View {
        if let card = model.card {
            VStack(spacing: 12) {
                content(card)
            }
            .padding(24)
            .frame(width: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .environment(\.colorScheme, .dark)
            .accessibilityIdentifier("macScreen.card")
        }
    }

    @ViewBuilder
    private func content(_ card: MacScreenCard) -> some View {
        switch card {
        case .confirm:
            Image(systemName: "desktopcomputer").font(.system(size: 28))
            Text(String(format: L.t("macScreen.card.confirmTitle", "Show %@?"), model.name)).font(.headline)
            Text(L.t("macScreen.card.confirmBody", "This tab was opened for you. Connect to see and control this Mac."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(L.t("macScreen.card.connect", "Connect"), action: actions.confirm)
                .accessibilityIdentifier("macScreen.card.confirm")
        case .missing:
            Image(systemName: "questionmark.square.dashed").font(.system(size: 28))
            Text(L.t("macScreen.card.missingTitle", "This Mac is not paired")).font(.headline)
            Text(L.t("macScreen.card.missingBody", "It was forgotten, or this tab came from another Mac. Pair it again from Mac Screen."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(L.t("macScreen.card.openHome", "Open Mac Screen"), action: actions.openHome)
        case let .connecting(reconnecting):
            ProgressView().controlSize(.regular)
            Text(reconnecting ? L.t("macScreen.card.reconnecting", "Reconnecting…")
                : String(format: L.t("macScreen.card.connecting", "Connecting to %@…"), model.name)).font(.headline)
            Button(L.t("macScreen.card.cancel", "Cancel"), action: actions.disconnect)
        case .waitingForPicture:
            ProgressView().controlSize(.regular)
            Text(L.t("macScreen.card.waiting", "Waiting for the screen…")).font(.headline)
        case .failed:
            // The session's message can quote the signaling URL (with the room id): never shown.
            Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(.yellow)
            Text(L.t("macScreen.card.failedTitle", "Couldn’t connect")).font(.headline)
            Text(L.t("macScreen.card.failedHint", "Check that Share This Mac is on and the other Mac is awake."))
                .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Button(L.t("macScreen.card.closeTab", "Close Tab"), action: actions.closeTab)
                Button(L.t("macScreen.card.retry", "Try Again"), action: actions.connect).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("macScreen.card.retry")
            }
        case .ended:
            Image(systemName: "display").font(.system(size: 28))
            Text(L.t("macScreen.card.endedTitle", "Disconnected")).font(.headline)
            HStack {
                Button(L.t("macScreen.card.closeTab", "Close Tab"), action: actions.closeTab)
                Button(L.t("macScreen.card.reconnect", "Reconnect"), action: actions.connect).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("macScreen.card.reconnect")
            }
        }
    }
}
