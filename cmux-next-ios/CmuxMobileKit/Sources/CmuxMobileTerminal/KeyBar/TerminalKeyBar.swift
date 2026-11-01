#if os(iOS)
import AudioToolbox
import CmuxMobileDesign
import SwiftUI

/// The key row (classic cmux iOS's accessory toolbar): pinned at the leading
/// edge the keyboard key, the joystick and the compose key; then a scroller
/// of keys that hug their labels, in classic's order, ending in Hide Toolbar.
/// It shows whether or not the keyboard is up. Each key is its own Liquid
/// Glass cap (classic: `.glass()` / `.prominentGlass()`), in cmux NEXT's
/// small-radius shape; there is no bar behind them.
struct TerminalKeyBar: View {
    let model: TerminalModel
    /// Scroller keys clipped at its edges (`KeyBarClipping`): hidden from
    /// accessibility, offered as row actions.
    @State private var clipped = KeyBarClippedKeys()
    /// The pinned keys' width: nothing is drawn under them.
    @State private var pinnedWidth: CGFloat = 0
    /// How far the row is scrolled past its start (points).
    @State private var scrolled: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal) {
            // Its own view, fed only reference types: the per-frame
            // `scrolled` updates below re-evaluate this bar's body, but
            // SwiftUI skips the ~30 glass keys' bodies when their inputs are
            // unchanged (they were rebuilt every scroll frame: the lag).
            KeyBarScrollerKeys(model: model, clipped: clipped)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.x + geometry.contentInsets.leading
        } action: { _, new in
            // The fade only depends on the first `KeyRowFade.width` points:
            // past them the value stops changing, so the bar stops updating.
            let clamped = min(KeyRowFade.width, max(0, new.rounded()))
            if clamped != scrolled { scrolled = clamped }
        }
        // Keys dissolve over 24 pt as they reach the pinned keys, more the
        // farther the row is scrolled, as under an iOS toolbar (classic's
        // `AccessoryEdgeFadeScrollView`); nothing is drawn under the pinned
        // glass keys themselves. iOS's own soft edge effect is hidden on this
        // edge: over these glass keys it drew a uniform dim band with a hard
        // seam where it ended.
        .mask(alignment: .leading) {
            let edge = KeyRowFade().leadingEdgeAlpha(scrolled: scrolled)
            HStack(spacing: 0) {
                Color.clear.frame(width: pinnedWidth)
                LinearGradient(colors: [.black.opacity(edge), .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: KeyRowFade.width)
                Rectangle()
            }
            // Measured from the scroller's own edge, not its safe area (the bar's inset).
            .ignoresSafeArea()
        }
        .scrollEdgeEffectHidden(true, for: .leading)
        // The pinned keys are the scroller's leading bar, as a toolbar is a
        // scroll view's: the keys scroll under them.
        .safeAreaBar(edge: .leading, spacing: TerminalDockMetrics.keySpacing) {
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 6) {
                    KeyboardToggleKey(model: model)
                    Joystick(engine: model.joystickEngine)
                    KeyCap(key: .composer, model: model)
                        .accessibilityLabel(model.composerPresented ? "Hide Text Field" : "Show Text Field")
                }
                .padding(.leading, TerminalDockMetrics.horizontalInset)
            }
            // The gaps between the pinned keys take their taps too, so none
            // falls through to a hidden key scrolled under them.
            .contentShape(.rect)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pinnedWidth = $0 }
        }
        // Room above and below the 28 pt row for the glass's touch lift,
        // which the scroller would otherwise clip; the row's layout height
        // stays 28 pt.
        .contentMargins(.vertical, KeyRowGlass.liftRoom, for: .scrollContent)
        .frame(height: TerminalDockMetrics.keyRowHeight + 2 * KeyRowGlass.liftRoom)
        .padding(.vertical, -KeyRowGlass.liftRoom)
        .tint(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("More keys")
        .accessibilityActions {
            ForEach(KeyBarKey.row.filter { clipped.keys.contains($0) }, id: \.self) { key in
                Button(key.accessibilityLabel) { model.keyBar(key) }
            }
        }
    }
}

/// Scroller keys whose center is under the pinned keys or past the edge.
/// Observable so only readers of `keys` update when a key crosses an edge.
@Observable @MainActor
final class KeyBarClippedKeys {
    private(set) var keys: Set<KeyBarKey> = []

    func set(_ key: KeyBarKey, clipped: Bool) {
        // Write only on a real change: every write invalidates readers.
        if clipped, !keys.contains(key) { keys.insert(key) }
        if !clipped, keys.contains(key) { keys.remove(key) }
    }
}

/// The scroller's keys, in classic's order, ending in Hide Toolbar.
struct KeyBarScrollerKeys: View {
    let model: TerminalModel
    let clipped: KeyBarClippedKeys

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: TerminalDockMetrics.keySpacing) {
                ForEach(KeyBarKey.row, id: \.self) { key in
                    KeyBarScrollerKey(key: key, model: model, clipped: clipped)
                }
            }
            .padding(.trailing, TerminalDockMetrics.horizontalInset)
        }
    }
}

/// One scroller key; it reads only its own clipped flag.
struct KeyBarScrollerKey: View {
    let key: KeyBarKey
    let model: TerminalModel
    let clipped: KeyBarClippedKeys

    var body: some View {
        let isClipped = clipped.keys.contains(key)
        Group {
            if key == .paste {
                // The system paste control: no "Allow Paste" prompt (Codex QA F14).
                PasteKeyCap(model: model)
                    .frame(width: TerminalDockMetrics.minKeyWidth, height: TerminalDockMetrics.keyRowHeight)
                    .keyGlass(armed: false)
            } else {
                KeyCap(key: key, model: model)
            }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            // Measured on iOS 26.5: the scroll view's visible bounds already
            // start after its leading bar (the pinned keys), so a key under
            // them reads as clipped with no offset here.
            KeyBarClipping().isActivatable(CGRect(origin: .zero, size: proxy.size), in: proxy.bounds(of: .scrollView))
        } action: { visible in
            clipped.set(key, clipped: !visible)
        }
        // A key under the pinned keys is neither seen, read nor tapped.
        .accessibilityHidden(isClipped)
        .allowsHitTesting(!isClipped)
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
        .keyGlass(armed: false)
        .accessibilityLabel(shown ? "Hide Keyboard" : "Show Keyboard")
        .accessibilityIdentifier("terminal.key.keyboard")
    }
}

/// One key cap: Liquid Glass, 28 pt tall, hugging its label (a glyph key is
/// 32 pt wide), radius 8. A Button keeps the scroller scrollable; arrows
/// repeat while held.
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
                        .font(.system(size: 13, weight: .medium))
                } else {
                    Text(key.label)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(locked || armed ? Color.cmuxMobileOnAccent : key == .hideChrome ? Color.primary.opacity(0.72) : .primary)
        }
        .buttonStyle(KeyCapStyle(locked: locked, armed: armed,
                                 width: key.isGlyph ? TerminalDockMetrics.minKeyWidth : nil))
        .keyGlass(armed: locked || armed)
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

/// A key cap's shape and size: 28 pt tall, hugging its label (a glyph key is
/// 32 pt wide), radius 8 (cmux NEXT draws no capsules). The glass is
/// `keyGlass`; pressed, the label dims a little under the glass's own lift.
struct KeyCapStyle: ButtonStyle {
    var locked = false
    var armed = false
    /// A fixed width; nil hugs the label with a 6 pt inset.
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, width == nil ? 6 : 0)
            .frame(minWidth: width ?? TerminalDockMetrics.minKeyWidth, maxWidth: width,
                   minHeight: TerminalDockMetrics.keyRowHeight, maxHeight: TerminalDockMetrics.keyRowHeight)
            .overlay(alignment: .bottom) {
                // Locked: a 2 pt underline under the armed tint (SPEC M1).
                if locked {
                    Capsule().fill(Color.cmuxMobileOnAccent).frame(height: 2).padding(.horizontal, 7).padding(.bottom, 2)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.rect(cornerRadius: KeyRowGlass.cornerRadius, style: .continuous))
    }
}

/// The key row's Liquid Glass (classic: `UIButton.Configuration.glass()`,
/// `.prominentGlass()` with the accent when a modifier is armed or locked;
/// the monochrome accent, never blue: design/ios.md).
enum KeyRowGlass {
    static let cornerRadius: CGFloat = 8
    /// Space the scroller leaves above and below its keys for the glass's lift on touch.
    static let liftRoom: CGFloat = 8
}

extension View {
    func keyGlass(armed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: KeyRowGlass.cornerRadius, style: .continuous)
        return glassEffect(armed ? .regular.tint(Color.cmuxMobileAccent).interactive() : .regular.interactive(), in: shape)
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
        // The glass behind it is drawn by SwiftUI (`keyGlass`), like every other key.
        configuration.baseBackgroundColor = .clear
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
