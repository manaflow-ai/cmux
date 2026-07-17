public import Foundation

/// A semantic, app-wide mobile toast.
///
/// Factory methods constrain the visual hierarchy and timing so call sites
/// choose meaning without rebuilding toast chrome.
public struct MobileToast: Identifiable, Sendable {
    /// Stable identity for presentation and cancellation.
    public let id: UUID

    let content: MobileToastContent
    let tone: MobileToastTone
    let lifetime: MobileToastLifetime
    let coalescingKey: String?
    let accessibilityIdentifier: String?
    let action: MobileToastAction?
    let feedback: MobileToastFeedback?

    private init(
        id: UUID = UUID(),
        content: MobileToastContent,
        tone: MobileToastTone,
        lifetime: MobileToastLifetime,
        coalescingKey: String?,
        accessibilityIdentifier: String?,
        action: MobileToastAction?,
        feedback: MobileToastFeedback?
    ) {
        self.id = id
        self.content = content
        self.tone = tone
        self.lifetime = lifetime
        self.coalescingKey = coalescingKey
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
        self.feedback = feedback
    }

    /// Creates a brief success confirmation.
    public static func success(
        _ message: MobileToastText,
        coalescingKey: String? = nil,
        accessibilityIdentifier: String? = nil,
        playsFeedback: Bool = true
    ) -> Self {
        Self(
            content: .compact(message),
            tone: .success,
            lifetime: .brief,
            coalescingKey: coalescingKey,
            accessibilityIdentifier: accessibilityIdentifier,
            action: nil,
            feedback: playsFeedback ? .success : nil
        )
    }

    /// Creates a brief informational update.
    public static func information(
        _ message: MobileToastText,
        coalescingKey: String? = nil,
        accessibilityIdentifier: String? = nil
    ) -> Self {
        Self(
            content: .compact(message),
            tone: .information,
            lifetime: .brief,
            coalescingKey: coalescingKey,
            accessibilityIdentifier: accessibilityIdentifier,
            action: nil,
            feedback: nil
        )
    }

    /// Creates a detailed, neutral notice with an optional action.
    public static func notice(
        title: MobileToastText,
        message: MobileToastText? = nil,
        action: MobileToastAction? = nil,
        coalescingKey: String? = nil,
        accessibilityIdentifier: String? = nil
    ) -> Self {
        Self(
            content: .detailed(title: title, message: message),
            tone: .information,
            lifetime: action == nil ? .standard : .long,
            coalescingKey: coalescingKey,
            accessibilityIdentifier: accessibilityIdentifier,
            action: action,
            feedback: nil
        )
    }

    /// Creates a detailed warning with an optional recovery action.
    public static func warning(
        title: MobileToastText,
        message: MobileToastText? = nil,
        action: MobileToastAction? = nil,
        coalescingKey: String? = nil,
        accessibilityIdentifier: String? = nil,
        playsFeedback: Bool = true
    ) -> Self {
        Self(
            content: .detailed(title: title, message: message),
            tone: .warning,
            lifetime: action == nil ? .standard : .long,
            coalescingKey: coalescingKey,
            accessibilityIdentifier: accessibilityIdentifier,
            action: action,
            feedback: playsFeedback ? .warning : nil
        )
    }

    /// Creates a detailed error with an optional recovery action.
    public static func error(
        title: MobileToastText,
        message: MobileToastText? = nil,
        action: MobileToastAction? = nil,
        coalescingKey: String? = nil,
        accessibilityIdentifier: String? = nil,
        playsFeedback: Bool = true
    ) -> Self {
        Self(
            content: .detailed(title: title, message: message),
            tone: .error,
            lifetime: action == nil ? .standard : .long,
            coalescingKey: coalescingKey,
            accessibilityIdentifier: accessibilityIdentifier,
            action: action,
            feedback: playsFeedback ? .error : nil
        )
    }

    /// Creates a persistent progress update that must be replaced or dismissed.
    public static func progress(
        title: MobileToastText,
        message: MobileToastText? = nil,
        coalescingKey: String? = nil,
        accessibilityIdentifier: String? = nil
    ) -> Self {
        Self(
            content: .progress(title: title, message: message),
            tone: .information,
            lifetime: .persistent,
            coalescingKey: coalescingKey,
            accessibilityIdentifier: accessibilityIdentifier,
            action: nil,
            feedback: nil
        )
    }
}
