#if os(iOS)
import AudioToolbox
import CmuxMobileDesign
import SwiftUI

/// The key row (classic cmux iOS's accessory toolbar): pinned at the leading
/// edge the keyboard key, the joystick and the compose key; then a scroller
/// of keys that hug their labels, in classic's order, ending in Hide Toolbar.
/// It shows whether or not the keyboard is up. Each key is its own cap in
/// cmux NEXT's key style; there is no bar behind them.
struct TerminalKeyBar: View {
    let model: TerminalModel
    /// Scroller keys clipped at its edges (`KeyBarClipping`): hidden from
    /// accessibility, offered as row actions.
    @State private var clipped: Set<KeyBarKey> = []
    @State private var edges = KeyBarScrollEdges()

    var body: some View {
        HStack(spacing: 6) {
            KeyboardToggleKey(model: model)
            Joystick(engine: model.joystickEngine)
            KeyCap(key: .composer, model: model)
            scroller
        }
        .padding(.leading, TerminalDockMetrics.horizontalInset)
        .frame(height: TerminalDockMetrics.keyRowHeight)
        .tint(.primary)
    }

    private var scroller: some View {
        ScrollView(.horizontal) {
            HStack(spacing: TerminalDockMetrics.keySpacing) {
                ForEach(KeyBarKey.row, id: \.self) { key in
                    Group {
                        if key == .paste {
                            // The system paste control: no "Allow Paste" prompt (Codex QA F14).
                            PasteKeyCap(model: model)
                                .frame(width: TerminalDockMetrics.minKeyWidth, height: TerminalDockMetrics.keyRowHeight)
                        } else {
                            KeyCap(key: key, model: model)
                        }
                    }
                    .onGeometryChange(for: Bool.self) { proxy in
                        KeyBarClipping().isActivatable(CGRect(origin: .zero, size: proxy.size), in: proxy.bounds(of: .scrollView))
                    } action: { visible in
                        if visible { clipped.remove(key) } else { clipped.insert(key) }
                    }
                    .accessibilityHidden(clipped.contains(key))
                }
            }
            // The row runs to the screen's edge; the 4 pt gap after the
            // compose key lives inside the scroller, so a key scrolled left
            // dissolves at the compose key's edge (classic).
            .padding(.leading, TerminalDockMetrics.keySpacing)
            .padding(.trailing, TerminalDockMetrics.horizontalInset)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: KeyBarScrollEdges.self) { geometry in
            KeyBarScrollEdges(offset: geometry.contentOffset.x, contentWidth: geometry.contentSize.width,
                              visibleWidth: geometry.containerSize.width)
        } action: { _, new in
            edges = new
        }
        .mask {
            // Keys fade out at the leading edge as they scroll under the
            // pinned keys; the trailing edge is the screen's.
            GeometryReader { proxy in
                let lead = edges.fadesLeading ? KeyBarScrollEdges.fade / max(1, proxy.size.width) : 0
                LinearGradient(stops: [
                    .init(color: edges.fadesLeading ? .clear : .black, location: 0),
                    .init(color: .black, location: lead),
                    .init(color: .black, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("More keys")
        .accessibilityActions {
            ForEach(KeyBarKey.row.filter { clipped.contains($0) }, id: \.self) { key in
                Button(key.accessibilityLabel) { model.keyBar(key) }
            }
        }
    }
}

/// The key row's first key (classic): the keyboard's glyph while it is down
/// (tap: show it for the last input target), the hide glyph while it is up.
/// The glyph cross-dissolves in 0.2 s.
struct KeyboardToggleKey: View {
    let model: TerminalModel

    var body: some View {
        let shown = model.keyboardVisible
        Button {
            model.toggleKeyboard()
        } label: {
            Image(systemName: shown ? "keyboard.chevron.compact.down" : "keyboard")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.78))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: shown)
        }
        .buttonStyle(KeyCapStyle(width: TerminalDockMetrics.keyRowHeight + 12))
        .accessibilityLabel(shown ? "Hide Keyboard" : "Show Keyboard")
        .accessibilityIdentifier("terminal.key.keyboard")
    }
}

/// One key cap: 28 pt tall, hugging its label (a glyph key is 32 pt wide),
/// radius 8, `fill`; pressed: `fillPressed` + 0.92. A Button keeps the
/// scroller scrollable; arrows repeat while held.
struct KeyCap: View {
    let key: KeyBarKey
    let model: TerminalModel
    @State private var taps = 0
    @AppStorage(CmuxMobilePreferences.Key.keyClicks) private var keyClicks = CmuxMobilePreferences.defaultKeyClicks

    private var stickyState: TerminalStickyModifiers.State? {
        key.modifier.map { model.sticky.state($0) }
    }

    var body: some View {
        let state = stickyState
        let locked = state == .locked
        let armed = if case .armed = state { true } else { false }
        Button {
            taps += 1
            if keyClicks { KeyClick.play() }
            model.keyBar(key)
        } label: {
            Group {
                if let symbol = key.symbolName {
                    Image(systemName: symbol)
                        .font(.system(size: key == .composer ? 11 : 13, weight: .medium))
                } else {
                    Text(key.label)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(locked || armed ? Color.white : key == .hideChrome ? Color.primary.opacity(0.72) : .primary)
        }
        .buttonStyle(KeyCapStyle(locked: locked, armed: armed, quiet: key == .hideChrome,
                                 width: key.isGlyph ? TerminalDockMetrics.minKeyWidth : nil))
        .buttonRepeatBehavior(key.repeats ? .enabled : .disabled)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: taps)
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityValue(locked ? "locked" : armed ? "armed" : "")
        .accessibilityIdentifier("terminal.key.\(key.identifier)")
    }
}

/// The system keyboard's click (Settings → Terminal → Key clicks). The key
/// row is not the keyboard's input view, so `UIDevice.playInputClick` stays
/// silent for it; this plays the same system sound, which follows the
/// ring/silent switch.
enum KeyClick {
    /// `Tock`, the keyboard key click.
    private static let sound: SystemSoundID = 1104

    static func play() { AudioServicesPlaySystemSound(sound) }
}

struct KeyCapStyle: ButtonStyle {
    var locked = false
    var armed = false
    /// Hide Toolbar reads as a control, not a key: no fill (classic).
    var quiet = false
    /// A fixed width; nil hugs the label with a 6 pt inset.
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, width == nil ? 6 : 0)
            .frame(minWidth: width ?? TerminalDockMetrics.minKeyWidth, maxWidth: width,
                   minHeight: TerminalDockMetrics.keyRowHeight, maxHeight: TerminalDockMetrics.keyRowHeight)
            .background(
                // Armed: accent fill, white label. Locked: the same plus a
                // 2 pt underline (SPEC M1). Rest: the quiet fill.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(locked || armed ? AnyShapeStyle(Color(uiColor: .systemBlue).opacity(configuration.isPressed ? 0.8 : 1))
                          : AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.22 : quiet ? 0 : 0.1)))
            )
            .overlay(alignment: .bottom) {
                if locked {
                    Capsule().fill(Color.white).frame(height: 2).padding(.horizontal, 7).padding(.bottom, 2)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(.rect)
    }
}

/// The key row's Paste: a `UIPasteControl` that pastes into the terminal
/// surface. A tap on it is the explicit paste gesture iOS trusts, so it never
/// raises the "Allow Paste" prompt (Codex QA F14).
struct PasteKeyCap: UIViewRepresentable {
    let model: TerminalModel

    func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = UIColor.label.withAlphaComponent(0.1)
        configuration.baseForegroundColor = .label
        let control = UIPasteControl(configuration: configuration)
        control.target = model.controller?.surface
        control.accessibilityIdentifier = "terminal.key.paste"
        return control
    }

    func updateUIView(_ control: UIPasteControl, context: Context) {
        if control.target == nil { control.target = model.controller?.surface }
    }
}
#endif
