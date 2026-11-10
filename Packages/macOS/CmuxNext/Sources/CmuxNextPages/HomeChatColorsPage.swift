import Foundation

extension PageDescriptor {
    /// Chat Colors (design/home.md "Chat Colors"): cmux-page://cmux.home-chat-colors/, built by
    /// scripts/cmux-next/build-pages-web.sh from webviews/src/pages/home-chat-colors. Its host and
    /// ops (`cmux.home.chatColors.*`) are CmuxNextHome's HomeChatColorsService and HomeChatColorsProvider.
    public static let homeChatColors = PageDescriptor(id: "cmux.home-chat-colors", resource: "home-chat-colors",
                                                      namespaces: ["cmux.home.chatColors."], commands: [])
}
