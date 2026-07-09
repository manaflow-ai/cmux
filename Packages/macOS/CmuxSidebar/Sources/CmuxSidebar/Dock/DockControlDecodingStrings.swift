import Foundation

/// App-localized decode error messages for ``DockControlDefinition``.
///
/// `CmuxSidebar` has no localization bundle, so `DockControlDefinition`'s
/// `init(from:)` cannot call `String(localized:)` (it would bind to the package
/// bundle, drop every non-English translation, and silently return the English
/// default). The app injects these already-localized strings through the
/// decoder's `userInfo` under ``CodingUserInfoKey/dockControlDecodingStrings``;
/// when absent, the decoder falls back to the English defaults below so the
/// type stays decodable in isolation (e.g. package tests).
public struct DockControlDecodingStrings: Sendable {
    /// Message thrown when a control's `id` normalizes to an empty string.
    public let blankControlID: String
    /// Message thrown when a control's `command` normalizes to an empty string.
    public let blankControlCommand: String
    /// Message thrown when a browser control's `url` normalizes to an empty string.
    public let blankControlURL: String
    /// Message thrown when a control's `type` is neither `terminal` nor `browser`.
    public let unknownControlType: String

    /// Creates a localized-strings bundle for Dock control decoding.
    public init(
        blankControlID: String,
        blankControlCommand: String,
        blankControlURL: String,
        unknownControlType: String
    ) {
        self.blankControlID = blankControlID
        self.blankControlCommand = blankControlCommand
        self.blankControlURL = blankControlURL
        self.unknownControlType = unknownControlType
    }
}

extension CodingUserInfoKey {
    /// Decoder `userInfo` slot carrying the app-localized
    /// ``DockControlDecodingStrings`` used by ``DockControlDefinition/init(from:)``.
    public static let dockControlDecodingStrings = CodingUserInfoKey(rawValue: "cmux.dock.controlDecodingStrings")!
}
