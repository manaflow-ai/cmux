#if os(iOS)
import SwiftUI
import UIKit

/// The agent chat's look under the Mac's (Leo, 2026-11-17: "the lack of themeing/background
/// inheriting (these need to be improved)"). hostd decides what the chat shows (`appearance.rs`
/// `chat_look`: the theme's ground, the picture under the window's tint, the picked bubble colors);
/// the colors the theme implies come from ``CmuxMobileMacPalette`` (`ThemeTokens.derive`, the code
/// the Mac's chrome runs). This only draws them.
public struct CmuxMobileChatLook: Equatable {
    /// Whether the theme is dark: the chat's text, cards and composer take that style.
    public var isDark: Bool
    /// The theme's background, opaque.
    public var background: CmuxMobileRGBA
    /// How much of ``background`` covers ``picture`` (1 with none).
    public var backgroundOpacity: Double
    /// The Mac's picture behind the chat, once it is on this phone.
    public var picture: UIImage?
    /// The person's own messages: the Mac's picked sent color, else the theme's raised surface.
    public var userBubble: CmuxMobileRGBA
    /// Their text: the Mac's picked sent text color, else the style's label.
    public var userBubbleText: CmuxMobileRGBA?

    public init(chat: CmuxMobileMacAppearance.Chat, palette: CmuxMobileMacPalette, picture: UIImage?) {
        isDark = palette.isDark
        background = CmuxMobileRGBA(hex: chat.background)
        backgroundOpacity = picture == nil ? 1 : min(1, max(0, chat.backgroundOpacity))
        self.picture = picture
        userBubble = chat.bubbles?.sent.map { CmuxMobileRGBA(hex: $0) } ?? palette.surfaceRaised
        userBubbleText = chat.bubbles?.sentText.map { CmuxMobileRGBA(hex: $0) }
    }

    public var colorScheme: ColorScheme { isDark ? .dark : .light }
    public var interfaceStyle: UIUserInterfaceStyle { isDark ? .dark : .light }

    /// The flat color of the chat's ground (the band under the status bar, the composer's fade).
    public var groundColor: UIColor { background.uiColor }

    /// The look the chat draws now (``CmuxMobileMacTheme/chatLook``); nil: the stock chat.
    public static var current: CmuxMobileChatLook? { CmuxMobileMacTheme.shared.chatLook }
}

extension UIColor {
    /// The person's own message bubble: the chat look's, else the stock bubble. Resolved each time a
    /// view's traits resolve it.
    public static let cmuxMobileChatBubble = UIColor { traits in
        CmuxMobileChatLook.current?.userBubble.uiColor ?? UIColor.cmuxMobileBubble.resolvedColor(with: traits)
    }

    /// The text in that bubble: the chat look's picked color, else the label.
    public static let cmuxMobileChatBubbleText = UIColor { traits in
        CmuxMobileChatLook.current?.userBubbleText?.uiColor ?? UIColor.label.resolvedColor(with: traits)
    }
}

extension Color {
    /// ``UIColor/cmuxMobileChatBubble``; read in a body, the view redraws when the look changes.
    public static var cmuxMobileChatBubble: Color {
        CmuxMobileChatLook.current.map { Color(uiColor: $0.userBubble.uiColor) } ?? .cmuxMobileBubble
    }

    /// The bubble's text color when the Mac picked one, else nil (the view's own).
    public static var cmuxMobileChatBubbleText: Color? {
        CmuxMobileChatLook.current?.userBubbleText.map { Color(uiColor: $0.uiColor) }
    }
}

/// The ground behind the agent chat: the Mac's picture under its theme color at the window's tint,
/// or the theme color alone; the stock background while there is no chat look.
public struct CmuxMobileChatBackdrop: View {
    private let macTheme: CmuxMobileMacTheme

    public init(macTheme: CmuxMobileMacTheme = .shared) {
        self.macTheme = macTheme
    }

    public var body: some View {
        if let look = macTheme.chatLook {
            let ground = Color(uiColor: look.background.uiColor)
            if let picture = look.picture {
                GeometryReader { proxy in
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .overlay(ground.opacity(look.backgroundOpacity))
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .accessibilityIdentifier("agentChat.macBackdrop")
            } else {
                ground
                    .ignoresSafeArea()
                    .accessibilityIdentifier("agentChat.macBackdrop")
            }
        } else {
            Color.cmuxMobileBackground
        }
    }
}

extension View {
    /// The chat's text, cards and composer in the light or dark style of the Mac's theme while the
    /// chat follows the Mac; unchanged otherwise.
    public func cmuxMobileChatLookStyle(_ look: CmuxMobileChatLook?) -> some View {
        modifier(ChatLookStyle(scheme: look?.colorScheme))
    }
}

private struct ChatLookStyle: ViewModifier {
    let scheme: ColorScheme?

    func body(content: Content) -> some View {
        if let scheme {
            content.environment(\.colorScheme, scheme)
        } else {
            content
        }
    }
}
#endif
