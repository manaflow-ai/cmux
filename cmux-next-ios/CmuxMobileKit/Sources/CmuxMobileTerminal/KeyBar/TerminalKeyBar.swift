#if os(iOS)
import AudioToolbox
import CmuxMobileDesign
import SwiftUI

/// The key row (classic cmux iOS's accessory toolbar): pinned at the leading
/// edge the keyboard key, the joystick and the compose key; then a scroller
/// of keys that hug their labels, in `KeyBarLayout`'s order (classic's, with
/// the arrows before the agent launchers), ending in Hide Toolbar.
/// It shows whether or not the keyboard is up. Each key is its own Liquid
/// Glass cap (classic: `.glass()` / `.prominentGlass()`), in cmux NEXT's
/// small-radius shape; there is no bar behind them.
struct TerminalKeyBar: View {
    let model: TerminalModel
    var layout: KeyBarLayout = .current
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
            // unchanged (they were rebuilt every scroll frame: the lag). The
            // layout is a plain enum, so it keeps that.
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.78))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2).unlessReduceMotion, value: shown)
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
            .cmuxMobilePressFill(configuration.isPressed,
                                 in: RoundedRectangle(cornerRadius: KeyRowGlass.cornerRadius, style: .continuous))
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
    /// Paste's own cap (`PasteKeyCap`): opaque, the tone of a glass key over
    /// the terminal's black.
    static let pasteBackground = UIColor(white: 0.2, alpha: 1)
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
        configuration.baseForegroundColor = .white
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
