public import Foundation

/// The AppKit `NSWindow.identifier` convention for cmux main windows.
///
/// Every cmux main window carries an `NSUserInterfaceItemIdentifier` whose raw
/// value is either the legacy bare token `cmux.main` (the first/primary window
/// before per-window identity existed) or `cmux.main.<uuid>` where `<uuid>` is
/// the window's ``WindowID/rawValue`` `UUID`. The app target sets this string at
/// window creation and reads it back to map an `NSWindow` to a ``WindowID``.
///
/// This was inlined at ~8 sites in the app delegate as a literal `"cmux.main."`
/// prefix plus hand-rolled parse/build/match. Centralizing the prefix and the
/// three pure value transforms (parse, build, match) here keeps the single
/// `UUID` <-> `String` convention in one place; the app target keeps its
/// `NSWindow` <-> ``WindowID`` resolution and forwards the encode/decode/match
/// to these members.
extension WindowID {
    /// The shared prefix every prefixed main-window identifier carries. The
    /// trailing dot separates the prefix from the encoded `UUID`.
    private static let mainWindowIdentifierPrefix = "cmux.main."

    /// The legacy bare identifier carried by the primary main window from before
    /// per-window identity existed. It encodes no ``WindowID``.
    private static let legacyBareMainWindowIdentifier = "cmux.main"

    /// Parses a ``WindowID`` out of an `NSWindow.identifier` raw value.
    ///
    /// Returns `nil` when `rawValue` is not a `cmux.main.<uuid>` string, which
    /// includes the legacy bare `cmux.main` token (it carries no `UUID`). Use
    /// ``isMainWindowIdentifier(_:)`` to test main-window membership, which the
    /// bare token does satisfy.
    public init?(mainWindowIdentifier rawValue: String) {
        guard rawValue.hasPrefix(Self.mainWindowIdentifierPrefix) else { return nil }
        let suffix = String(rawValue.dropFirst(Self.mainWindowIdentifierPrefix.count))
        guard let uuid = UUID(uuidString: suffix) else { return nil }
        self.init(uuid)
    }

    /// The `NSWindow.identifier` raw value the app target assigns to the main
    /// window bearing this ``WindowID``: the prefix followed by the underlying
    /// `UUID`'s string form.
    public var mainWindowIdentifierRawValue: String {
        Self.mainWindowIdentifierPrefix + rawValue.uuidString
    }

    /// Reports whether `rawValue` identifies any cmux main window: the legacy
    /// bare `cmux.main` token or any `cmux.main.<uuid>` string. Unlike
    /// ``init(mainWindowIdentifier:)``, this accepts the bare token (which has no
    /// encodable ``WindowID``).
    public static func isMainWindowIdentifier(_ rawValue: String) -> Bool {
        rawValue == legacyBareMainWindowIdentifier
            || rawValue.hasPrefix(mainWindowIdentifierPrefix)
    }
}
