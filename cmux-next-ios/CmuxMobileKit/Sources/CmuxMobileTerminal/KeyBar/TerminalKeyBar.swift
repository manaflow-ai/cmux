#if os(iOS)
import AudioToolbox
import CmuxMobileDesign
import SwiftUI

/// The key row (classic cmux iOS's accessory toolbar): pinned at the leading
/// edge the keyboard key, the joystick and the compose key; then a scroller
/// of keys that hug their labels, in `KeyBarLayout`'s order (classic's, with
/// the arrows before the agent launchers), ending in Hide Toolbar.
/// It shows only over the soft keyboard (`TerminalDockVisibility.showsKeyRow`).
/// Every key is classic's 28 pt cap, and its cap is its whole hit area. How the keys are drawn is `KeyBarStyle`:
/// separate Liquid Glass caps (classic: `.glass()` / `.prominentGlass()`), in
/// cmux NEXT's small-radius shape, by default.
struct TerminalKeyBar: View {
    let model: TerminalModel
    var layout: KeyBarLayout = .current
    @Environment(\.keyBarStyle) private var style
    /// Scroller keys clipped at its edges (`KeyBarClipping`): hidden from
    /// accessibility, offered as row actions.
    @State private var clipped = KeyBarClippedKeys()

    var body: some View {
        ScrollView(.horizontal) {
            // Its own view, fed only reference types and a plain enum, so
            // SwiftUI skips the ~30 glass keys' bodies when the bar's body
            // runs again with the same inputs.
            KeyBarScrollerKeys(model: model, layout: layout, clipped: clipped)
        }
        .scrollIndicators(.hidden)
        // At rest a key an edge cuts is not drawn (`KeyBarClipping.isWhole`):
        // the row ended in a sliver of a key at the trailing edge (iOS release
        // bar read-back: "no clipped keys"). While the finger scrolls, every
        // key is drawn.
        .onScrollPhaseChange { _, phase in
            if clipped.resting != (phase == .idle) { clipped.resting = phase == .idle }
        }
        // Apple's scroll edge effect, not a hand-made mask: keys soften as
        // they slide under the pinned keys (the scroller's leading bar, so
        // the system draws the effect behind them) and off the trailing
        // edge. Soft, the style iOS gives a toolbar over scrolling content
        // (HIG, Scroll views: "scroll edge effect").
        .scrollEdgeEffectStyle(.soft, for: .horizontal)
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
        }
        // Room above and below the 28 pt row for the glass's touch lift,
        // which the scroller would otherwise clip; the row's layout height
        // stays 28 pt.
        .contentMargins(.vertical, KeyRowGlass.liftRoom, for: .scrollContent)
        .frame(height: TerminalDockMetrics.keyRowHeight + 2 * KeyRowGlass.liftRoom)
        .padding(.vertical, -KeyRowGlass.liftRoom)
        // The glass lift is visual only. Keep the row's hit region inside its
        // 28 pt layout so taps in the composer gap belong to the composer.
        .frame(height: TerminalDockMetrics.keyRowHeight)
        .contentShape(Rectangle())
        // The strip style: one glass bar behind every key, like the system
        // keyboard's own suggestion bar, instead of a cap per key.
        .background {
            if style == .strip {
                RoundedRectangle(cornerRadius: KeyRowGlass.stripCornerRadius, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: KeyRowGlass.stripCornerRadius, style: .continuous))
                    .padding(.horizontal, TerminalDockMetrics.horizontalInset - 4)
                    .allowsHitTesting(false)
            }
        }
        .tint(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("More keys")
        .accessibilityActions {
            ForEach(layout.scroller.filter { clipped.keys.contains($0) }, id: \.self) { key in
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
    /// Keys an edge cuts (not wholly inside the visible bounds).
    private(set) var cut: Set<KeyBarKey> = []
    /// The row isn't being scrolled: cut keys are not drawn.
    var resting = true

    func set(_ key: KeyBarKey, clipped: Bool) {
        // Write only on a real change: every write invalidates readers.
        if clipped, !keys.contains(key) { keys.insert(key) }
        if !clipped, keys.contains(key) { keys.remove(key) }
    }

    func set(_ key: KeyBarKey, cut isCut: Bool) {
        if isCut, !cut.contains(key) { cut.insert(key) }
        if !isCut, cut.contains(key) { cut.remove(key) }
    }

    /// Whether `key` is drawn: always while scrolling, at rest only whole.
    func draws(_ key: KeyBarKey) -> Bool {
        !(resting && cut.contains(key))
    }
}

/// The scroller's keys (`KeyBarLayout`), ending in Hide Toolbar.
struct KeyBarScrollerKeys: View {
    let model: TerminalModel
    let layout: KeyBarLayout
    let clipped: KeyBarClippedKeys

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: TerminalDockMetrics.keySpacing) {
                ForEach(layout.scroller, id: \.self) { key in
                    KeyBarScrollerKey(key: key, model: model, clipped: clipped)
                }
            }
            .padding(.trailing, TerminalDockMetrics.horizontalInset)
        }
    }
}

/// Where a scroller key sits against the row's visible bounds.
struct KeyBarKeyVisibility: Equatable {
    var activatable: Bool
    var whole: Bool
}

/// One scroller key; it reads only its own clipped flag.
struct KeyBarScrollerKey: View {
    let key: KeyBarKey
    let model: TerminalModel
    let clipped: KeyBarClippedKeys

    var body: some View {
        let isClipped = clipped.keys.contains(key)
        let drawn = clipped.draws(key)
        Group {
            if key == .paste {
                // The system paste control: no "Allow Paste" prompt (Codex QA F14).
                // It draws its own cap: no glass over it (`PasteKeyCap`).
                PasteKeyCap(model: model)
                    // A paste control's colours are fixed when it is made (writing them later throws),
                    // so a new Mac theme makes a new control.
                    .id(PasteKeyCap.ThemeKey(palette: CmuxMobileMacTheme.shared.palette))
                    .frame(width: TerminalDockMetrics.minKeyWidth, height: TerminalDockMetrics.keyRowHeight)
                    .clipShape(RoundedRectangle(cornerRadius: KeyRowGlass.cornerRadius, style: .continuous))
            } else {
                KeyCap(key: key, model: model)
            }
        }
        .onGeometryChange(for: KeyBarKeyVisibility.self) { proxy in
            // Measured on iOS 26.5: the scroll view's visible bounds already
            // start after its leading bar (the pinned keys), so a key under
            // them reads as clipped with no offset here.
            let frame = CGRect(origin: .zero, size: proxy.size)
            let visible = proxy.bounds(of: .scrollView)
            return KeyBarKeyVisibility(activatable: KeyBarClipping().isActivatable(frame, in: visible),
                                       whole: KeyBarClipping().isWhole(frame, in: visible))
        } action: { visibility in
            clipped.set(key, clipped: !visibility.activatable)
            clipped.set(key, cut: !visibility.whole)
        }
        .opacity(drawn ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: drawn)
        // A key under the pinned keys is neither seen, read nor tapped.
        .accessibilityHidden(isClipped)
        .allowsHitTesting(!isClipped && drawn)
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
                .font(.system(size: KeyCapStyle.glyphSize, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.78))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2).unlessReduceMotion, value: shown)
        }
        .buttonStyle(KeyCapStyle(width: TerminalDockMetrics.minKeyWidth + 8))
        .accessibilityLabel(shown ? "Hide Keyboard" : "Show Keyboard")
        .accessibilityIdentifier("terminal.key.keyboard")
    }
}

/// One key cap: 28 pt tall, hugging its label (a glyph key is 32 pt wide),
/// radius 8. A Button keeps the scroller scrollable; arrows repeat
/// while held. No haptic: these are keys, and whether keys tick is the system
/// keyboard's own Keyboard Feedback setting, which no app can read (Leo,
/// 2026-11-23: "dont inject haptic noise when i havent asked for it. ever.").
/// The click plays only when the person turned Key clicks on (off by default).
struct KeyCap: View {
    let key: KeyBarKey
    let model: TerminalModel
    @AppStorage(CmuxMobilePreferences.Key.keyClicks) private var keyClicks = CmuxMobilePreferences.defaultKeyClicks

    private var stickyState: TerminalStickyModifiers.State? {
        key.modifier.map { model.sticky.state($0) }
    }

    var body: some View {
        let state = stickyState
        // Wide shows as a locked key while it is on.
        let locked = state == .locked || (key == .wide && model.wideOutput)
        let armed = if case .armed = state { true } else { false }
        Button {
            if keyClicks { KeyClick.play() }
            model.keyBar(key)
        } label: {
            Group {
                if let symbol = key.symbolName {
                    Image(systemName: symbol)
                        .font(.system(size: KeyCapStyle.glyphSize, weight: .medium))
                } else {
                    Text(key.label)
                        .font(.system(size: KeyCapStyle.labelSize, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(locked || armed ? Color.cmuxMobileOnAccent : key == .hideChrome ? Color.primary.opacity(0.72) : .primary)
        }
        .buttonStyle(KeyCapStyle(locked: locked, armed: armed,
                                 width: key.isGlyph ? TerminalDockMetrics.minKeyWidth : nil))
        .buttonRepeatBehavior(key.repeats ? .enabled : .disabled)
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityValue(key == .wide ? (model.wideOutput ? "on" : "off") : locked ? "locked" : armed ? "armed" : "")
        .accessibilityIdentifier("terminal.key.\(key.identifier)")
    }
}

/// The system keyboard's click, only when the person turned Settings →
/// Terminal → Key clicks on (off by default: no sound they did not ask for).
/// The key row is not the keyboard's input view, so `UIDevice.playInputClick`
/// stays silent for it; this plays the same system sound, which follows the
/// ring/silent switch. The app's one raw sound call, behind that opt-in.
enum KeyClick {
    /// `Tock`, the keyboard key click.
    private static let sound: SystemSoundID = 1104

    static func play() { AudioServicesPlaySystemSound(sound) }
}

/// A key cap's shape and size: 28 pt tall, hugging its label (a glyph key is
/// 32 pt wide), radius 8 (cmux NEXT draws no capsules). Its look follows
/// `KeyBarStyle`; pressed, the label dims a little under the glass's own lift.
struct KeyCapStyle: ButtonStyle {
    /// SF Symbol keys, and text keys (Esc, Tab, ^C): classic's 13 and 14 pt
    /// (#53325 had 17 and 16 for its 44 pt caps).
    static let glyphSize: CGFloat = 13
    static let labelSize: CGFloat = 14

    var locked = false
    var armed = false
    /// A fixed width; nil hugs the label with a 6 pt inset.
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        KeyCapBody(label: configuration.label, pressed: configuration.isPressed,
                   locked: locked, armed: armed, width: width)
    }
}

/// `KeyCapStyle`'s drawing, a view so it reads the row's `KeyBarStyle`.
private struct KeyCapBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let locked: Bool
    let armed: Bool
    let width: CGFloat?
    @Environment(\.keyBarStyle) private var style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: KeyRowGlass.cornerRadius, style: .continuous)
        let inset = style.capInset
        label
            .padding(.horizontal, width == nil ? 6 : 0)
            .frame(minWidth: (width ?? TerminalDockMetrics.minKeyWidth) - 2 * inset, maxWidth: width.map { $0 - 2 * inset },
                   minHeight: TerminalDockMetrics.keyRowHeight - 2 * inset,
                   maxHeight: TerminalDockMetrics.keyRowHeight - 2 * inset)
            .overlay(alignment: .bottom) {
                // Locked: a 2 pt underline under the armed tint (SPEC M1).
                if locked {
                    Capsule().fill(Color.cmuxMobileOnAccent).frame(height: 2).padding(.horizontal, 7).padding(.bottom, 2)
                }
            }
            .cmuxMobilePressFill(pressed, in: shape)
            .keyGlass(style: style, armed: locked || armed)
            // The drawn cap may be smaller than its slot (`KeyBarStyle.inset`):
            // the whole slot takes the tap, and no more.
            .padding(inset)
            .contentShape(.rect(cornerRadius: KeyRowGlass.cornerRadius, style: .continuous))
    }
}

/// How the key row draws its keys. Every style keeps the same targets; the
/// gallery (`-cmux-mobile-recovery-gallery keybar`) shows them side by side.
enum KeyBarStyle: String, CaseIterable, Sendable {
    /// A Liquid Glass cap per key (the shipped look).
    case caps
    /// One glass bar behind plain keys, like the system keyboard's suggestion
    /// bar; only an armed modifier gets its own (accent) cap.
    case strip
    /// Smaller glass caps centered in the same targets: a lighter look.
    case inset

    var title: String {
        switch self {
        case .caps: "Caps (a glass cap per key)"
        case .strip: "Strip (one glass bar)"
        case .inset: "Inset (smaller caps, same targets)"
        }
    }

    /// How far the drawn cap sits inside its target, each side.
    var capInset: CGFloat { self == .inset ? 2 : 0 }
}

extension EnvironmentValues {
    @Entry var keyBarStyle: KeyBarStyle = .caps
}

/// The key row's Liquid Glass (classic: `UIButton.Configuration.glass()`,
/// `.prominentGlass()` with the accent when a modifier is armed or locked;
/// the monochrome accent, never blue: design/ios.md).
enum KeyRowGlass {
    static let cornerRadius: CGFloat = 8
    /// The strip style's bar (`KeyBarStyle.strip`).
    static let stripCornerRadius: CGFloat = 12
    /// Space the scroller leaves above and below its keys for the glass's lift on touch.
    static let liftRoom: CGFloat = 8
    /// Paste's own cap (`PasteKeyCap`): opaque, the theme's raised surface (the
    /// tone of a glass key over the terminal's ground), so it follows the Mac's theme.
    static var pasteBackground: UIColor { CmuxMobileTheme.standard.colors.surfaceRaised.uiColor }
    /// Paste's glyph: the theme's text color.
    static var pasteForeground: UIColor { CmuxMobileTheme.standard.colors.label.uiColor }
}

extension View {
    /// A key's glass: its own cap, or (the strip style) none but an armed
    /// modifier's accent cap.
    @ViewBuilder
    func keyGlass(style: KeyBarStyle = .caps, armed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: KeyRowGlass.cornerRadius, style: .continuous)
        if style == .strip, !armed {
            self
        } else {
            glassEffect(armed ? .regular.tint(Color.cmuxMobileAccent).interactive() : .regular.interactive(), in: shape)
        }
    }
}

/// The key row's Paste: a `UIPasteControl` that pastes into the terminal
/// surface. A tap on it is the explicit paste gesture iOS trusts, so it never
/// raises the "Allow Paste" prompt (Codex QA F14).
///
/// iOS draws the control's glyph itself and draws nothing when it cannot
/// show that glyph plainly: covered by another layer, or with no contrast
/// to its background. The key drew blank (Leo's screenshot, 2026-11-21)
/// with a clear background under SwiftUI's glass, which wraps the view in
/// its own layers. So the control draws its own opaque cap in the glass
/// keys' tone, with no glass over it.
struct PasteKeyCap: UIViewRepresentable {
    let model: TerminalModel

    func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .medium
        // Opaque, near the dark glass keys over the terminal's black.
        configuration.baseBackgroundColor = KeyRowGlass.pasteBackground
        configuration.baseForegroundColor = KeyRowGlass.pasteForeground
        let control = UIPasteControl(configuration: configuration)
        control.target = model.controller?.surface
        control.accessibilityIdentifier = "terminal.key.paste"
        return control
    }

    func updateUIView(_ control: UIPasteControl, context: Context) {
        if control.target == nil { control.target = model.controller?.surface }
    }

    /// The Mac theme the control was made in: its `.id`, so a theme change makes a new control.
    struct ThemeKey: Hashable {
        let palette: CmuxMobileMacPalette?
        func hash(into hasher: inout Hasher) {}
    }
}
#endif
