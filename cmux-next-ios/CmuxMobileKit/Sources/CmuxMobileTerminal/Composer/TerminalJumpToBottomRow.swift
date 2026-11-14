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

    var body: some View {
        ZStack {
            if showsJumpToBottom {
                Button {
                    model.scrollToBottom()
                } label: {
                    Label("Jump to bottom", systemImage: "arrow.down")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .glassSurface(in: .rect(cornerRadius: KeyRowGlass.cornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scroll to bottom")
                .accessibilityIdentifier("terminal.jumpToBottom")
                .padding(.bottom, TerminalDockMetrics.keyRowGap)
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
