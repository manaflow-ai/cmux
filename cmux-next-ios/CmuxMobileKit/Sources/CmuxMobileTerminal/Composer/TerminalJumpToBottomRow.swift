#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// The terminal's Jump to bottom pill, centered just above the key row
/// (CMUX-10). Shown only while scrolled up in scroll mode, never for a TUI,
/// and removable in Settings > Terminal.
///
/// It floats over the page's last rows and takes no space: it used to be a
/// row of the bottom stack, so showing it lifted the page's end by its
/// height and drew the stack's backing behind it, a blank band (Leo,
/// 2026-11-23: "it seems like y'all have added an additional row of
/// blanking? ... bring it back down to where it was and simply make the ios
/// tap easier"). Its host is the size of its tap target, so nothing around
/// it eats a touch, and the pill is a solid fill, not interactive glass,
/// whose own touch handling left dead spots in the drawn pill (Leo: "theres
/// also these weird dead zones in the jump to bottom in terminal... dont add
/// blur there").
struct TerminalJumpToBottomRow: View {
    @Bindable var model: TerminalModel
    @AppStorage(CmuxMobilePreferences.Key.terminalJumpToBottom)
    private var jumpToBottomEnabled = CmuxMobilePreferences.defaultTerminalJumpToBottom

    private var showsJumpToBottom: Bool {
        JumpToBottomVisibility.showsInTerminal(scrolledUp: model.isScrolledUp, isTUI: model.isTUI, enabled: jumpToBottomEnabled)
    }

    /// Taps so far: each one plays a light haptic.
    @State private var taps = 0

    var body: some View {
        ZStack {
            if showsJumpToBottom {
                Button {
                    taps += 1
                    // The tap that hid the pill, or a second one where it
                    // was, never also lands on the shell (Leo, 2026-11-23).
                    model.controller?.quietShellTaps()
                    model.scrollToBottom()
                } label: {
                    Label("Jump to bottom", systemImage: "arrow.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(CmuxMobileTheme.standard.colors.label)
                        .padding(.horizontal, 12)
                        .frame(height: Self.pillHeight)
                        .cmuxMobilePressBackground(Self.pillFill, in: Self.pillShape)
                        .overlay { Self.pillShape.strokeBorder(Self.pillEdge, lineWidth: 0.5) }
                        // The pill looks the same; its tap target is larger (Leo,
                        // 2026-11-22: "make the tapping of the jump to bottom button
                        // ... a bit easier to tap"). It reaches out sideways, up into
                        // the page and down across the gap to the key row, so the
                        // target is `hitHeight` tall, past Apple's 44 pt minimum
                        // (HIG, Accessibility: "at least 44x44 pt").
                        .padding(.horizontal, Self.hitSlop)
                        .padding(.top, Self.hitHeight - Self.pillHeight - TerminalDockMetrics.keyRowGap)
                        .padding(.bottom, TerminalDockMetrics.keyRowGap)
                        .contentShape(.rect)
                }
                .buttonStyle(.cmuxPressFillInLabel)
                .sensoryFeedback(.impact(weight: .light), trigger: taps)
                .accessibilityLabel("Scroll to bottom")
                .accessibilityIdentifier("terminal.jumpToBottom")
                // It rises out of the key row: up 14 pt from 92 % and
                // transparent, on a light spring. Its removal is at once
                // (the animation below is nil for a hide).
                .transition(.asymmetric(insertion: .modifier(active: JumpRise(progress: 0), identity: JumpRise(progress: 1)),
                                        removal: .identity))
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            model.controller?.jumpRowHeightChanged(height)
        }
        // Shown with the rise; gone at once when following starts (a Jump to
        // bottom tap: qa11 wt-fling-c, the row still drawn after the page
        // reached the bottom, and a row shrinking over 0.2 s moved the page's
        // inset on every frame of the jump).
        // Reduce Motion: no animation.
        .animation(showsJumpToBottom ? Animation.cmuxMobileSnappy.unlessReduceMotion : nil, value: showsJumpToBottom)
    }

    /// The pill as drawn.
    static let pillHeight: CGFloat = 28
    static let pillShape = RoundedRectangle(cornerRadius: KeyRowGlass.cornerRadius, style: .continuous)
    /// Opaque, the tone of a key over the terminal's black: no blur.
    static let pillFill = Color(uiColor: KeyRowGlass.pasteBackground)
    static let pillEdge = Color.white.opacity(0.14)
    /// The tap target's height, the key-row gap included (56 pt until Leo,
    /// 2026-11-23: "making the jump to bottom be more clickable").
    static let hitHeight: CGFloat = 64
    /// The tap target's reach past each side of the pill (was 28 pt).
    static let hitSlop: CGFloat = 44
    /// Around the target, a near miss is ignored by the shell rather than
    /// taken as a tap into the terminal (`TerminalViewController.nearShellButton`).
    static let nearMissMargin: CGFloat = 16
}

/// The pill's entrance: from 14 pt low, 92 % and transparent (0) to its
/// place (1).
private struct JumpRise: ViewModifier {
    var progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(0.92 + 0.08 * progress, anchor: .bottom)
            .offset(y: 14 * (1 - progress))
    }
}
#endif
