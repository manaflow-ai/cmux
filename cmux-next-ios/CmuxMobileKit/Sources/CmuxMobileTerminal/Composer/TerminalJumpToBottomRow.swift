#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// The terminal's Jump to bottom pill: the top row of the bottom stack, above
/// the key row and below the terminal's last drawn row (CMUX-10). It takes
/// part in the stack's layout, so the page's rows end above it instead of
/// under it (a floating button hid the end of the lines: Codex QA F3), and it
/// no longer sits between the key row and the composer. Centered, shown only
/// while scrolled up in scroll mode, never for a TUI, and removable in
/// Settings > Terminal. Hidden, the row is 0 pt tall.
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
                    model.scrollToBottom()
                } label: {
                    Label("Jump to bottom", systemImage: "arrow.down")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: Self.pillHeight)
                        .glassSurface(in: .rect(cornerRadius: KeyRowGlass.cornerRadius, style: .continuous))
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
                .buttonStyle(.cmuxPressGlass)
                .sensoryFeedback(.impact(weight: .light), trigger: taps)
                .accessibilityLabel("Scroll to bottom")
                .accessibilityIdentifier("terminal.jumpToBottom")
                .frame(maxWidth: .infinity, alignment: .center)
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
    /// The tap target's height, the key-row gap included.
    static let hitHeight: CGFloat = 56
    /// The tap target's reach past each side of the pill.
    static let hitSlop: CGFloat = 28
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
