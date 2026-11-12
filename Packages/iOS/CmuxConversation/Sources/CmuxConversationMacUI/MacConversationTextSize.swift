#if os(macOS)
import AppKit

/// View > Make Text Bigger / Make Text Normal Size / Make Text Smaller.
///
/// Messages keeps one text size for the app (its `TextSize` step and
/// `TextFontSize` in the com.apple.MobileSMS defaults), so every
/// conversation window follows the same value and it survives relaunch.
/// Changing it re-derives the transcript metrics in `MacConversationTheme`
/// and posts `didChange`; each transcript drops its layout cache and reflows.
enum MacConversationTextSize {
    /// Body sizes the commands step through. 13 pt is Messages' default; this
    /// Mac's Messages reports step 6 at 15 pt, consistent with 1 pt steps
    /// around the default (the larger steps are lower confidence).
    static let steps: [CGFloat] = [10, 11, 12, 13, 14, 15, 17, 20, 24]
    static let defaultSize = MacConversationTheme.defaultBodyFontSize
    static let defaultsKey = "cmux.conversation.textFontSize"
    static let didChange = Notification.Name("cmux.conversation.textSizeDidChange")

    /// Where the size persists (tests swap in a private suite).
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// The persisted size, snapped to a step; the default when unset.
    static func storedSize() -> CGFloat {
        let stored = CGFloat(defaults.double(forKey: defaultsKey))
        return steps.contains(stored) ? stored : defaultSize
    }

    static var current: CGFloat { MacConversationTheme.bodyFont.pointSize }

    private static var index: Int { steps.firstIndex(of: current) ?? steps.firstIndex(of: defaultSize)! }

    static var canMakeBigger: Bool { index < steps.count - 1 }
    static var canMakeSmaller: Bool { index > 0 }
    static var isNormal: Bool { current == defaultSize }

    @MainActor static func makeBigger() { if canMakeBigger { set(steps[index + 1]) } }
    @MainActor static func makeSmaller() { if canMakeSmaller { set(steps[index - 1]) } }
    @MainActor static func makeNormal() { set(defaultSize) }

    @MainActor static func set(_ size: CGFloat) {
        guard size != current else { return }
        MacConversationTheme.setBodyFontSize(size)
        if size == defaultSize {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(Double(size), forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
#endif
