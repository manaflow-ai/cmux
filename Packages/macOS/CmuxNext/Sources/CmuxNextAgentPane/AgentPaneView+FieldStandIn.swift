public import AppKit

/// What a New Tab field stand-in hands the page's field (``AgentPaneView/showFieldStandIn()``).
public nonisolated struct NewTabFieldSeed: Sendable, Equatable, Encodable {
    public var text: String
    /// The selection, in UTF-16 offsets of `text`.
    public var selectionStart: Int
    public var selectionEnd: Int
    /// Return was pressed in the stand-in: the page submits once it took the text.
    public var submit: Bool

    public init(text: String, selectionStart: Int, selectionEnd: Int, submit: Bool) {
        (self.text, self.selectionStart, self.selectionEnd, self.submit) = (text, selectionStart, selectionEnd, submit)
    }
}

extension AgentPaneView {
    /// Red-test stub: no stand-in yet.
    public func showFieldStandIn() -> NSView? { nil }

    /// The stand-in now shown, nil when none.
    public var fieldStandIn: NSView? { nil }

    /// Where a stand-in's text goes (tests).
    public var fieldSeedSink: (@MainActor (NewTabFieldSeed) -> Void)? {
        get { nil }
        set { _ = newValue }
    }
}
