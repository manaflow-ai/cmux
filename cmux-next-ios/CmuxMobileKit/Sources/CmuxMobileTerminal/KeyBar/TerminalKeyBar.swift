#if os(iOS)
import AudioToolbox
import CmuxMobileDesign
import SwiftUI

/// The key row (classic cmux iOS's accessory toolbar): pinned at the leading
/// edge the joystick and the compose key; then a scroller of keys that hug
/// their labels, in `KeyBarLayout`'s order (the terminal keys, then the agent
/// launchers last after a hairline); pinned at the trailing edge the one
/// keyboard key (tap: show or hide the keyboard; long-press: Hide Toolbar
/// Too). Every key takes touches over 44 x 44 pt (`KeyRowHitTarget`).
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
    /// The trailing keyboard key's width: nothing is drawn under it either.
    @State private var trailingWidth: CGFloat = 0
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
                Color.clear.frame(width: trailingWidth)
            }
            // Measured from the scroller's own edge, not its safe area (the bar's inset).
            .ignoresSafeArea()
        }
        .scrollEdgeEffectHidden(true, for: [.leading, .trailing])
        // The pinned keys are the scroller's leading bar, as a toolbar is a
        // scroll view's: the keys scroll under them.
        .safeAreaBar(edge: .leading, spacing: TerminalDockMetrics.keySpacing) {
            GlassEffectContainer(spacing: 0) {
                // No spacing: each key's 44 pt hit area holds its share of the gap.
                HStack(spacing: 0) {
                    Joystick(engine: model.joystickEngine)
                    KeyCap(key: .composer, model: model)
                        .accessibilityLabel(model.composerPresented ? "Hide Text Field" : "Show Text Field")
                }
                .padding(.leading, TerminalDockMetrics.horizontalInset - KeyRowHitTarget.gap / 2)
            }
            // The gaps between the pinned keys take their taps too, so none
            // falls through to a hidden key scrolled under them.
            .contentShape(.rect)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pinnedWidth = $0 }
        }
        // The one keyboard control, at the trailing edge: before there were
        // three (this key at the leading edge, a nav-bar button and Hide
        // Toolbar at the scroller's end).
        .safeAreaBar(edge: .trailing, spacing: TerminalDockMetrics.keySpacing) {
            GlassEffectContainer(spacing: 0) {
                KeyboardToggleKey(model: model)
                    .padding(.trailing, TerminalDockMetrics.horizontalInset - KeyRowHitTarget.gap / 2)
            }
            .contentShape(.rect)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
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

    func set(_ key: KeyBarKey, clipped: Bool) {
        // Write only on a real change: every write invalidates readers.
        if clipped, !keys.contains(key) { keys.insert(key) }
        if !clipped, keys.contains(key) { keys.remove(key) }
    }
}

/// The scroller's keys (`KeyBarLayout`), the launchers last after a hairline.
struct KeyBarScrollerKeys: View {
    let model: TerminalModel
    let layout: KeyBarLayout
    let clipped: KeyBarClippedKeys

    var body: some View {
        let separatorKey = layout.launcherSeparatorKey
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: TerminalDockMetrics.keySpacing) {
                ForEach(layout.scroller, id: \.self) { key in
                    if key == separatorKey { KeyRowHairline() }
                    KeyBarScrollerKey(key: key, model: model, clipped: clipped)
                }
            }
        }
    }
}

/// The hairline before the agent launchers: they are commands, not keys.
struct KeyRowHairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.3))
            .frame(width: 1 / displayScale, height: 18)
            .padding(.horizontal, 5)
            .accessibilityHidden(true)
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
                // It draws its own cap: no glass over it (`PasteKeyCap`).
                // Its view is the whole 44 x 44 pt hit area; it draws its cap
                // inside (`PasteKeyHitView`).
                PasteKeyCap(model: model)
                    .frame(width: KeyRowHitTarget.minimum, height: KeyRowHitTarget.minimum)
                    .padding(.vertical, -KeyRowHitTarget.verticalSlop)
            } else if case .launcher(let launcher) = key {
                KeyCap(key: key, model: model)
                    // A tap only types the command; running it is a choice.
                    .contextMenu {
                        Button("Run Now", systemImage: "return") { model.runLauncher(launcher) }
                        Button("Insert", systemImage: "text.insert") { model.keyBar(key) }
                    }
                    .accessibilityHint("Types \(launcher.command) without running it. Touch and hold to run it now.")
                    .accessibilityAction(named: "Run Now") { model.runLauncher(launcher) }
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

/// The key row's one keyboard control, pinned at its trailing edge: the
/// keyboard's glyph while it is down (tap: show it for the last input
/// target), the hide glyph while it is up; the glyph cross-dissolves in
/// 0.2 s. Its long-press menu's Hide Toolbar Too takes the key row, the
/// composer and the keyboard away until the next terminal tap (it was a
/// key at the scroller's end).
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
        .contextMenu {
            Button(shown ? "Hide Keyboard" : "Show Keyboard",
                   systemImage: shown ? "keyboard.chevron.compact.down" : "keyboard") { model.toggleKeyboard() }
            Button("Hide Toolbar Too", systemImage: "chevron.down.square") { model.hideToolbar() }
        }
        .accessibilityLabel(shown ? "Hide Keyboard" : "Show Keyboard")
        .accessibilityHint("Touch and hold to hide the toolbar too.")
        .accessibilityAction(named: "Hide Toolbar Too") { model.hideToolbar() }
        .accessibilityIdentifier("terminal.key.keyboard")
    }
}

/// One key cap: Liquid Glass, 28 pt tall, hugging its label (a glyph key is
/// 38 pt wide), radius 8, in a 44 x 44 pt hit area. An agent launcher leads
/// with a dim `›_`: it types a command. A Button keeps the scroller scrollable; arrows
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
                } else if key.isLauncher {
                    HStack(spacing: 3) {
                        Text("›_")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.55))
                        Text(key.label)
                            .font(.system(size: 14, weight: .medium))
                    }
                    .lineLimit(1)
                } else {
                    Text(key.label)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(locked || armed ? Color.cmuxMobileOnAccent : .primary)
        }
        .buttonStyle(KeyCapStyle(locked: locked, armed: armed,
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

/// A key cap's shape and size: 28 pt tall, hugging its label (a glyph key is
/// 38 pt wide), radius 8 (cmux NEXT draws no capsules), its glass
/// (`keyGlass`), then its 44 x 44 pt hit area around it (`keyRowHitArea`);
/// pressed, the label dims a little under the glass's own lift.
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
            // The glass on the cap, before the hit area grows the view.
            .keyGlass(armed: locked || armed)
            .keyRowHitArea()
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

    /// A key's hit area: at least 44 x 44 pt (Apple HIG, Accessibility:
    /// "a hit region of at least 44x44 pt",
    /// https://developer.apple.com/design/human-interface-guidelines/accessibility).
    /// Sideways it takes half the 6 pt gap on each side (and is at least
    /// 44 pt wide); up and down it reaches `KeyRowHitTarget.verticalSlop`
    /// past the 28 pt cap without changing the row's layout height.
    func keyRowHitArea() -> some View {
        padding(.horizontal, KeyRowHitTarget.gap / 2)
            .frame(minWidth: KeyRowHitTarget.minimum)
            .padding(.vertical, KeyRowHitTarget.verticalSlop)
            .contentShape(.rect)
            .padding(.vertical, -KeyRowHitTarget.verticalSlop)
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

    func makeUIView(context: Context) -> PasteKeyHitView {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .medium
        // Opaque, near the dark glass keys over the terminal's black.
        configuration.baseBackgroundColor = KeyRowGlass.pasteBackground
        configuration.baseForegroundColor = .white
        let control = UIPasteControl(configuration: configuration)
        control.target = model.controller?.surface
        control.accessibilityIdentifier = "terminal.key.paste"
        return PasteKeyHitView(control: control)
    }

    func updateUIView(_ view: PasteKeyHitView, context: Context) {
        if view.control.target == nil { view.control.target = model.controller?.surface }
    }
}

/// Paste's 44 x 44 pt hit area (`KeyRowHitTarget`) around its 38 x 28 pt
/// cap: the paste control draws only its cap, and a touch anywhere in the
/// area goes to it.
final class PasteKeyHitView: UIView {
    let control: UIPasteControl

    init(control: UIPasteControl) {
        self.control = control
        super.init(frame: .zero)
        control.layer.cornerRadius = KeyRowGlass.cornerRadius
        control.layer.cornerCurve = .continuous
        control.clipsToBounds = true
        addSubview(control)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let cap = CGSize(width: TerminalDockMetrics.minKeyWidth, height: TerminalDockMetrics.keyRowHeight)
        control.frame = CGRect(x: (bounds.width - cap.width) / 2, y: (bounds.height - cap.height) / 2,
                               width: cap.width, height: cap.height)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        // The nearest point of the cap: what a touch there would hit.
        let cap = control.frame.insetBy(dx: 1, dy: 1)
        let nearest = CGPoint(x: min(max(point.x, cap.minX), cap.maxX), y: min(max(point.y, cap.minY), cap.maxY))
        return control.hitTest(convert(nearest, to: control), with: event) ?? control
    }
}
#endif
