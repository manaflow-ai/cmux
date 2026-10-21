#if os(iOS)
import AudioToolbox
import CmuxMobileDesign
import SwiftUI

/// The key bar over the keyboard (SPEC B2): pinned `esc` `ctrl` `^C`, a
/// full-width scroller that snaps to whole keys and fades its edges, and the
/// joystick plus hide-keyboard at the trailing end, in one glass capsule.
struct TerminalKeyBar: View {
    let model: TerminalModel
    /// Middle-row keys clipped at the scroller's edges (`KeyBarClipping`):
    /// hidden from accessibility, offered as row actions.
    @State private var clipped: Set<KeyBarKey> = []
    @State private var edges = KeyBarScrollEdges()
    /// Keys the scroller's edges cut (not wholly visible).
    @State private var cut: Set<KeyBarKey> = []
    /// The row is being dragged or is decelerating or snapping.
    @State private var scrolling = false
    /// The width the scroller may take; it uses a whole number of keys of it.
    @State private var available: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(KeyBarKey.pinned, id: \.self) { key in
                KeyCap(key: key, model: model)
            }
            // The scroller is exactly a whole number of equal keys with 6 pt
            // gaps, so every snapped position shows whole keys with no hole
            // and no stretched gap (R3-5, round 5); the rest of the space goes
            // beside the joystick.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 34)
                .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { available = $0 }
                .overlay(alignment: .leading) { scroller }
            Joystick(engine: model.joystickEngine)
            Button {
                model.keyBar(.hideKeyboard)
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide Keyboard")
        }
        .padding(.horizontal, 4)
        .frame(height: 44)
        .background(Color(uiColor: CmuxMobileGhosttyApp.background).opacity(0.85), in: .capsule)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 6)
        .tint(.primary)
    }

    private var scroller: some View {
        ScrollView(.horizontal) {
            HStack(spacing: KeyBarLayout.spacing) {
                ForEach(KeyBarKey.middle, id: \.self) { key in
                    let hidesCut = !scrolling && cut.contains(key)
                    Group {
                        if key == .paste {
                            // The system paste control: no "Allow Paste" prompt (Codex QA F14).
                            PasteKeyCap(model: model).frame(width: KeyBarLayout.keyWidth, height: 34)
                        } else {
                            KeyCap(key: key, model: model, width: KeyBarLayout.keyWidth)
                        }
                    }

                            .onGeometryChange(for: Bool.self) { proxy in
                                KeyBarClipping().isActivatable(CGRect(origin: .zero, size: proxy.size), in: proxy.bounds(of: .scrollView))
                            } action: { visible in
                                if visible { clipped.remove(key) } else { clipped.insert(key) }
                            }
                            .onGeometryChange(for: Bool.self) { proxy in
                                KeyBarClipping().isWhole(CGRect(origin: .zero, size: proxy.size), in: proxy.bounds(of: .scrollView))
                            } action: { whole in
                                if whole { cut.remove(key) } else { cut.insert(key) }
                            }
                            // At rest, a key the edge cuts is not drawn: no sliver (R2-4).
                            .opacity(hidesCut ? 0 : 1)
                            .animation(.easeOut(duration: 0.12), value: hidesCut)
                            .accessibilityHidden(clipped.contains(key) || hidesCut)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .onScrollPhaseChange { _, phase in
                scrolling = phase != .idle
            }
            .onScrollGeometryChange(for: KeyBarScrollEdges.self) { geometry in
                KeyBarScrollEdges(offset: geometry.contentOffset.x, contentWidth: geometry.contentSize.width,
                                  visibleWidth: geometry.containerSize.width)
            } action: { _, new in
                edges = new
            }
            .mask {
                // One gradient over the whole row (strips side by side left
                // a hairline seam at rest, R1-3): opaque at the leading edge
                // until the row is scrolled; the trailing fade is wide enough
                // that a key cut at rest reads as fading, not as half a key (R1-4).
                GeometryReader { proxy in
                    let width = max(1, proxy.size.width)
                    let lead = edges.fadesLeading ? KeyBarScrollEdges.fade / width : 0
                    let fadesTrailing = scrolling && edges.fadesTrailing
                    let trail = fadesTrailing ? KeyBarScrollEdges.trailingFade / width : 0
                    LinearGradient(stops: [
                        .init(color: edges.fadesLeading ? .clear : .black, location: 0),
                        .init(color: .black, location: lead),
                        .init(color: .black, location: 1 - trail),
                        .init(color: fadesTrailing ? .clear : .black, location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                }
            }
            .frame(width: KeyBarLayout().scrollerWidth(available: available))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("More keys")
            .accessibilityActions {
                ForEach(KeyBarKey.middle.filter { clipped.contains($0) }, id: \.self) { key in
                    Button(key.accessibilityLabel) { model.keyBar(key) }
                }
            }
    }
}

/// One key cap: 40 x 34 (wider for words), radius 10, `fill`; pressed: `fillPressed` + 0.92.
/// A Button keeps the middle row scrollable; arrows repeat while held.
struct KeyCap: View {
    let key: KeyBarKey
    let model: TerminalModel
    /// The scroller's keys share one width (`KeyBarLayout.keyWidth`).
    var width: CGFloat?
    @State private var taps = 0
    @AppStorage(CmuxMobilePreferences.Key.keyClicks) private var keyClicks = CmuxMobilePreferences.defaultKeyClicks

    private var stickyState: TerminalStickyModifiers.State? {
        switch key {
        case .control: model.sticky.control
        case .alternate: model.sticky.alternate
        default: nil
        }
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
            Text(key.label)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundStyle(locked || armed ? Color.white : .primary)
        }
        .buttonStyle(KeyCapStyle(locked: locked, armed: armed, width: width))
        .buttonRepeatBehavior(key.repeats ? .enabled : .disabled)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: taps)
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityValue(locked ? "locked" : armed ? "armed" : "")
        .accessibilityIdentifier("terminal.key.\(key.identifier)")
    }
}

/// The system keyboard's click (Settings → Terminal → Key clicks). The key
/// bar is not the keyboard's input view, so `UIDevice.playInputClick` stays
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
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, width == nil ? 8 : 3)
            .frame(minWidth: width ?? 40, maxWidth: width, minHeight: 34)
            .background(
                // Armed: accent fill, white label. Locked: the same plus a
                // 2 pt underline (SPEC M1). Rest: the quiet fill.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(locked || armed ? AnyShapeStyle(Color(uiColor: .systemBlue).opacity(configuration.isPressed ? 0.8 : 1))
                          : AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.22 : 0.08)))
            )
            .overlay(alignment: .bottom) {
                if locked {
                    Capsule().fill(Color.white).frame(height: 2).padding(.horizontal, 8).padding(.bottom, 3)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(.rect)
    }
}

/// The key bar's Paste: a `UIPasteControl` that pastes into the terminal
/// surface. A tap on it is the explicit paste gesture iOS trusts, so it never
/// raises the "Allow Paste" prompt (Codex QA F14).
struct PasteKeyCap: UIViewRepresentable {
    let model: TerminalModel

    func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = UIColor.label.withAlphaComponent(0.08)
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
