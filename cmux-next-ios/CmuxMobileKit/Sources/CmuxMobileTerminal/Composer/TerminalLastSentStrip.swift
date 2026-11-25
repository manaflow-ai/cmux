#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// The terminal's top strip: the last line sent from the phone, just under
/// the status bar, while its row is off screen. One tap scrolls back to it
/// and marks its row for a moment (Leo, 2026-11-23: "i want to be able to
/// click (tap) the top bit of the terminal in phone to jump to that last sent
/// bit. making it clickable would be good cuz then i can properly use the
/// phone to examine stuff").
///
/// Before it, the top of the page showed only the status bar's scrim: no
/// sent line to tap. Shown only on the shell's scrollback (a full-screen app
/// owns its screen), and only once something was sent from this page. The
/// status bar's own tap (scroll to top) is untouched: the strip starts below it.
struct TerminalLastSentStrip: View {
    /// The look. The page uses `.pill`; the gallery shows all three
    /// (`-cmux-mobile-recovery-gallery lastsent`).
    enum Style: String, CaseIterable, Identifiable {
        /// A: a centered solid capsule, like Jump to bottom at the other end.
        case pill
        /// B: a full-width bar under the status bar.
        case bar
        /// C: the top edge alone, a thin rule with the arrow, no text.
        case edge

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pill: "A · Pill with the sent line (the page's)"
            case .bar: "B · Full-width bar"
            case .edge: "C · Top edge only"
            }
        }
    }

    @Bindable var model: TerminalModel
    var style: Style = .pill

    /// Taps so far: each one plays a light haptic.
    @State private var taps = 0

    var body: some View {
        ZStack {
            if let text = model.lastSentStripText {
                Self.Strip(text: text, style: style) {
                    taps += 1
                    model.jumpToLastSent()
                }
                .sensoryFeedback(.impact(weight: .light), trigger: taps)
                .transition(.opacity.combined(with: .offset(y: -8)))
            }
        }
        .animation(model.lastSentStripText != nil ? Animation.cmuxMobileSnappy.unlessReduceMotion : nil,
                   value: model.lastSentStripText != nil)
    }

    /// The control itself, for the page and the gallery.
    struct Strip: View {
        let text: String
        let style: Style
        let action: () -> Void

        var body: some View {
            Button(action: action) { label }
                // A solid fill, no blur, as Jump to bottom (Leo, 2026-11-23:
                // "dont add blur there"): interactive glass's own touch
                // handling left dead spots in the drawn pill.
                .buttonStyle(.cmuxPressFillInLabel)
                .accessibilityLabel("Jump to last sent: \(text)")
                .accessibilityIdentifier("terminal.lastSentStrip")
        }

        @ViewBuilder private var label: some View {
            switch style {
            case .pill:
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.to.line")
                        .font(.caption.weight(.bold))
                    Text(text)
                        .font(.system(.footnote, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: TerminalLastSentStrip.pillHeight)
                .frame(maxWidth: TerminalLastSentStrip.pillMaxWidth)
                .fixedSize(horizontal: true, vertical: false)
                .cmuxMobilePressBackground(TerminalJumpToBottomRow.pillFill, in: .capsule)
                .overlay { Capsule().strokeBorder(TerminalJumpToBottomRow.pillEdge, lineWidth: 0.5) }
                // The capsule as drawn; the target reaches 8 pt past it on
                // each side and down into the page, to `hitHeight` (past
                // Apple's 44 pt: HIG, Accessibility).
                .padding(.horizontal, TerminalLastSentStrip.hitSlop)
                .padding(.top, 4)
                .padding(.bottom, TerminalLastSentStrip.hitHeight - TerminalLastSentStrip.pillHeight - 4)
                .contentShape(.rect)
            case .bar:
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.to.line")
                        .font(.caption.weight(.bold))
                    Text(text)
                        .font(.system(.footnote, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text("Last sent")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: TerminalLastSentStrip.hitHeight)
                .cmuxMobilePressBackground(TerminalJumpToBottomRow.pillFill, in: .rect)
                .overlay(alignment: .bottom) { Divider() }
                .contentShape(.rect)
            case .edge:
                VStack(spacing: 2) {
                    Capsule().fill(.secondary).frame(width: 36, height: 4)
                    Image(systemName: "chevron.compact.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: TerminalLastSentStrip.hitHeight, alignment: .top)
                .padding(.top, 4)
                .cmuxMobilePressBackground(Color.clear, in: .rect)
                .contentShape(.rect)
            }
        }
    }

    /// The capsule as drawn, and the widest it gets before the text truncates.
    static let pillHeight: CGFloat = 32
    static let pillMaxWidth: CGFloat = 300
    /// The tap target's height (the capsule plus the reach below it).
    static let hitHeight: CGFloat = 48
    /// The tap target's reach past each side of the capsule.
    static let hitSlop: CGFloat = 12
}

#if DEBUG
/// The three looks of the top strip side by side over terminal rows, for
/// screenshots: launch with `-cmux-mobile-recovery-gallery lastsent`.
public struct TerminalLastSentGallery: View {
    public init() {}

    private static let rows = [
        "   Compiling cmux-mobile-host v0.1.0",
        "   Compiling cmux-mobile-link v0.1.0",
        "warning: unused variable: `frame`",
        "    Finished `release` profile in 41.2s",
        "~/src/cmux % ",
    ]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(TerminalLastSentStrip.Style.allCases) { style in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(style.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                        ZStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                // A fixed 10-row sample, drawn whole.
                                Text((Self.rows + Self.rows).joined(separator: "\n"))
                                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                            }
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            TerminalLastSentStrip.Strip(text: "cargo build --release -p cmux-mobile-host", style: style) {}
                                .accessibilityIdentifier("lastSentGallery.\(style.rawValue)")
                        }
                        .frame(height: 170, alignment: .top)
                        .background(Color.black)
                        .clipShape(.rect(cornerRadius: 12))
                        .padding(.horizontal, 12)
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .background(Color(white: 0.08))
        .environment(\.colorScheme, .dark)
    }
}
#endif
#endif
