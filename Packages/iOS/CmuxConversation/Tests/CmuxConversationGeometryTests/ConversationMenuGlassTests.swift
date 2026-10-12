import CmuxConversationGeometry
import Testing

struct ConversationMenuGlassTests {
    /// Messages' long-press menu (a UIKit context menu) reads 237,237,239
    /// over its 206,206,210 veil on iOS 26.5; a plain regular glass of that
    /// size reads 239,239,242, bluer and lighter. A faint warm-gray tint
    /// lands it on 237,237,239 (fitted in a glass probe at the menu's size).
    @Test func longPressLightGlassMatchesContextMenuPlatter() {
        let tint = ConversationMenuGlassTint.longPressLightIOS26
        #expect(tint == ConversationMenuGlassTint(red: 0.94, green: 0.94, blue: 0.938, alpha: 0.3))
    }

    /// iOS 27.0: Messages' menu reads 230,230,230 over its neutral 204 veil,
    /// where a plain regular glass of our menu's size reads 237,237,237. A
    /// 9 % mid-gray tint lands on 230 (glass probe at 250 x 241 pt).
    @Test func longPressLightGlassMatchesContextMenuPlatterOnIOS27() {
        let tint = ConversationMenuGlassTint.longPressLightIOS27
        #expect(tint == ConversationMenuGlassTint(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.09))
    }
}
