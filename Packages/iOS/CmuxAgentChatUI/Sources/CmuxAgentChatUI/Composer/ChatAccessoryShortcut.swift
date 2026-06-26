import SwiftUI

/// One host-provided shortcut rendered in the chat composer's horizontal row.
public struct ChatAccessoryShortcut: Identifiable {
    /// Chat-owned behaviors whose implementation must live in the composer,
    /// because the host-provided row item does not own focus, draft, or
    /// attachment state.
    public enum SemanticAction {
        /// Paste clipboard contents into the chat composer.
        case paste
        /// Dismiss the chat composer's keyboard.
        case dismissKeyboard
    }

    /// Stable identity for SwiftUI diffing and accessibility tests.
    public let id: String
    /// Short title shown on the button when ``systemImage`` is nil.
    public let title: String
    /// Optional SF Symbol shown instead of ``title``.
    public let systemImage: String?
    /// VoiceOver label for icon-only or abbreviated shortcuts.
    public let accessibilityLabel: String?
    /// Optional foreground tint for contextual actions.
    public let tint: Color?
    /// Optional composer-owned behavior attached to this visual shortcut.
    public let semanticAction: SemanticAction?
    private let action: () -> Void

    /// Creates a shortcut button model.
    /// - Parameters:
    ///   - id: Stable identity for the row item.
    ///   - title: Short title shown when no system image is supplied.
    ///   - systemImage: Optional SF Symbol shown instead of ``title``.
    ///   - accessibilityLabel: VoiceOver label for icon-only or abbreviated items.
    ///   - tint: Optional foreground tint.
    ///   - semanticAction: Optional composer-owned behavior for this item.
    ///   - action: Action to run when the shortcut is tapped.
    public init(
        id: String,
        title: String,
        systemImage: String? = nil,
        accessibilityLabel: String? = nil,
        tint: Color? = nil,
        semanticAction: SemanticAction? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.tint = tint
        self.semanticAction = semanticAction
        self.action = action
    }

    /// Runs the shortcut's tap action.
    public func perform() {
        action()
    }

    /// Returns the same visual shortcut with a different tap handler.
    public func replacingAction(_ action: @escaping () -> Void) -> ChatAccessoryShortcut {
        ChatAccessoryShortcut(
            id: id,
            title: title,
            systemImage: systemImage,
            accessibilityLabel: accessibilityLabel,
            tint: tint,
            semanticAction: semanticAction,
            action: action
        )
    }
}
