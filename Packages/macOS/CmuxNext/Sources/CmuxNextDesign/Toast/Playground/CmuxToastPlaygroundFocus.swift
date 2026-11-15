public import CmuxNextDesignTokens

/// Which styles the Toast Playground shows (``CmuxToastTunables/playgroundFocus``): every style, or one, to
/// look at it alone (and to shoot each style apart). The choices follow ``CmuxToastStyle`` itself.
public nonisolated struct CmuxToastPlaygroundFocus: TunableChoice, Hashable, Sendable {
    /// `all`, or a ``CmuxToastStyle`` raw value.
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue == Self.all.rawValue || CmuxToastStyle(rawValue: rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    private init(validated rawValue: String) { self.rawValue = rawValue }

    /// Every style.
    public static let all = CmuxToastPlaygroundFocus(validated: "all")

    /// One style alone.
    public static func only(_ style: CmuxToastStyle) -> CmuxToastPlaygroundFocus { CmuxToastPlaygroundFocus(validated: style.rawValue) }

    public static var allCases: [CmuxToastPlaygroundFocus] { [all] + CmuxToastStyle.allCases.map(only) }

    public var tunableTitle: String { CmuxToastStyle(rawValue: rawValue)?.title ?? "All styles" }

    /// The styles shown, in the playground's order.
    public var styles: [CmuxToastStyle] {
        CmuxToastStyle(rawValue: rawValue).map { [$0] } ?? CmuxToastStyle.allCases
    }
}
