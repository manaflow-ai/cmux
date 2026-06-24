public import Foundation

/// Field-editor state captured synchronously at Return time. The published
/// SwiftUI buffer and the debounced suggestion list can lag behind what the
/// field actually displays, so submit decisions must start from this snapshot.
///
/// It is a pure value passed across the omnibar UI (the AppKit field editor in
/// `CmuxBrowserUI`) and the submit-decision logic, so it is `Sendable`: every
/// stored property (`String`, `NSRange?`, `Bool`) is itself `Sendable`.
public struct OmnibarLiveFieldSnapshot: Equatable, Sendable {
    public var text: String
    public var selectionRange: NSRange?
    public var hasMarkedText: Bool

    public init(text: String, selectionRange: NSRange?, hasMarkedText: Bool) {
        self.text = text
        self.selectionRange = selectionRange
        self.hasMarkedText = hasMarkedText
    }
}
