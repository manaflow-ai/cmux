// DEBUG and Demo builds only: review variants for where Show Chat / Show Terminal lives on an
// agent terminal's page (Leo, 2026-11-18, ask-1105ee4cc6). None of them is the default and none
// removes anything: without the launch argument the page is exactly base's (the page menu row).
#if DEBUG && os(iOS)
import CmuxMobileDesign
import SwiftUI

/// Where an agent terminal's Chat / Terminal swap lives, for review.
/// `-cmux-mobile-terminal-chat-toggle-variant menu|navbar|gesture` (default `menu`, base).
///
/// - `menu`: only the page menu's Show Chat / Show Terminal row, as base has it. Nothing on the page.
/// - `navbar`: one small glass button at the top trailing corner, under the status bar, that names
///   the other face. Drawn only on a terminal whose agent has a chat (`faces.offered`).
/// - `gesture`: no permanent control. A swipe in from the trailing edge swaps the faces; the first
///   time a pair shows in a launch, a hint says so for a few seconds, beside a small edge grabber.
///
/// All three keep the page menu row: a variant adds a place, it never takes one away.
enum TerminalChatToggleVariant: String, CaseIterable {
    case menu, navbar, gesture

    static let launchArgument = "-cmux-mobile-terminal-chat-toggle-variant"

    static var current: TerminalChatToggleVariant {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: launchArgument), arguments.indices.contains(index + 1) else { return .menu }
        return TerminalChatToggleVariant(rawValue: arguments[index + 1]) ?? .menu
    }
}

/// The variant's control over a terminal chat pair's page (`TerminalChatPage`).
struct TerminalChatToggleVariantOverlay: ViewModifier {
    let variant: TerminalChatToggleVariant
    /// The tab offers both faces (Claude Code or Codex with a chat).
    let offered: Bool
    let showsChat: Bool
    let topInset: CGFloat
    let swap: () -> Void

    func body(content: Content) -> some View {
        switch variant {
        case .menu:
            content
        case .navbar:
            content.overlay(alignment: .topTrailing) {
                if offered {
                    TerminalChatNavButton(showsChat: showsChat, action: swap)
                        .padding(.top, topInset + 6)
                        .padding(.trailing, 14)
                }
            }
        case .gesture:
            content.overlay {
                if offered {
                    TerminalChatEdgeSwipe(showsChat: showsChat, topInset: topInset, swap: swap)
                }
            }
        }
    }
}

/// Variant `navbar`: one compact glass button that names the face a tap shows.
struct TerminalChatNavButton: View {
    let showsChat: Bool
    let action: () -> Void

    var body: some View {
        let theme = CmuxMobileTheme.standard
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: showsChat ? "terminal" : "bubble.left")
                    .font(.system(size: 13, weight: .semibold))
                Text(showsChat ? "Terminal" : "Chat")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(theme.colors.label.color)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .contentShape(.capsule)
        }
        .buttonStyle(.cmuxPressFill)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(showsChat ? "Show Terminal" : "Show Chat")
        .accessibilityIdentifier("terminalChat.variant.navbar")
    }
}

/// Variant `gesture`: a swipe in from the trailing edge swaps the faces. No control stays on
/// the page; the hint and the grabber show for a few seconds the first time a pair shows.
struct TerminalChatEdgeSwipe: View {
    let showsChat: Bool
    let topInset: CGFloat
    let swap: () -> Void

    /// Pairs shown in this launch: the hint shows once per launch (a review build only, so
    /// nothing is written to the person's defaults).
    @MainActor static var hinted = false
    @State private var hintVisible = false
    @State private var drag: CGFloat = 0

    /// How far in from the edge a swipe starts, and how far it travels to swap.
    static let edgeWidth: CGFloat = 22
    static let travel: CGFloat = 70
    /// How long the hint stays: longer in the review gallery, so its still is taken after launch settles.
    static var hintSeconds: Double {
        ProcessInfo.processInfo.arguments.contains("-cmux-mobile-terminal-chat-toggle-gallery") ? 12 : 4
    }

    var body: some View {
        let theme = CmuxMobileTheme.standard
        ZStack(alignment: .trailing) {
            Color.clear.allowsHitTesting(false)
            // The hit strip: only the trailing edge takes touches, so the terminal keeps its own
            // pans, selection and scroll everywhere else.
            Color.clear
                .frame(width: Self.edgeWidth)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { drag = min(0, $0.translation.width) }
                        .onEnded { value in
                            if value.translation.width < -Self.travel { swap() }
                            withAnimation(.snappy) { drag = 0 }
                        }
                )
                .accessibilityElement()
                .accessibilityLabel(showsChat ? "Show Terminal" : "Show Chat")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { swap() }
                .accessibilityIdentifier("terminalChat.variant.edge")
            Capsule()
                .fill(theme.colors.label.color.opacity(0.35))
                .frame(width: 4, height: 44)
                .padding(.trailing, 4)
                .offset(x: drag / 3)
                .opacity(hintVisible || drag != 0 ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if hintVisible {
                HStack(spacing: 8) {
                    Image(systemName: "hand.draw")
                    Text(showsChat ? "Swipe in from the right edge for the Terminal" : "Swipe in from the right edge for Chat")
                }
                .font(theme.type.meta.weight(.semibold))
                .foregroundStyle(theme.colors.label.color)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, topInset + 8)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityIdentifier("terminalChat.variant.hint")
            }
        }
        .task {
            guard !Self.hinted else { return }
            Self.hinted = true
            withAnimation(.easeOut(duration: 0.25)) { hintVisible = true }
            do { try await Task.sleep(for: .seconds(Self.hintSeconds)) } catch { return }
            withAnimation(.easeIn(duration: 0.4)) { hintVisible = false }
        }
    }
}
#endif
