public import Foundation

/// Immutable identity of an in-flight browser omnibar selection-repeat run.
///
/// The repeat coordinator compares the incoming key against the currently armed
/// key to decide whether to keep an existing repeat (when the same panel, key
/// code, and direction are still held) or to re-arm a fresh one. The three
/// fields together are the full identity of a repeat: which browser panel owns
/// the omnibar, which physical key is held, and which direction the selection
/// is moving.
public struct BrowserOmnibarRepeatKey: Sendable, Equatable {
    /// Identifier of the browser panel whose omnibar selection is repeating.
    public let panelID: UUID

    /// `keyCode` of the held key that drives the repeat.
    public let keyCode: UInt16

    /// Signed selection-move delta applied on each repeat tick.
    public let delta: Int

    /// Creates a repeat key from its panel, key code, and selection delta.
    /// - Parameters:
    ///   - panelID: Identifier of the owning browser panel.
    ///   - keyCode: `keyCode` of the held key.
    ///   - delta: Signed selection-move delta per tick.
    public init(panelID: UUID, keyCode: UInt16, delta: Int) {
        self.panelID = panelID
        self.keyCode = keyCode
        self.delta = delta
    }
}
