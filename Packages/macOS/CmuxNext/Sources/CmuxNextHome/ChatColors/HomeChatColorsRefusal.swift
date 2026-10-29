import Foundation

/// `cmux chat colors` was given a value that is not a colour (`--sent blue`).
public struct HomeChatColorsRefusal: LocalizedError, Equatable {
    /// The option (`sent`, `sentText`, `received`, `receivedText`).
    public let role: String
    /// The value given.
    public let value: String

    public var errorDescription: String? {
        String(format: String(localized: "home.chatColors.refusal.badColor",
                              defaultValue: "%1$@ is not a color for --%2$@: use #RRGGBB, or default.", bundle: .module), value, role)
    }
}
