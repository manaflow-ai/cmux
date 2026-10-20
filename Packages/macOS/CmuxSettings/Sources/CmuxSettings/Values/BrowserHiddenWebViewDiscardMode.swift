import Foundation

/// When hidden browser panes give their web content process back to the system.
public enum BrowserHiddenWebViewDiscardMode: String, CaseIterable, Sendable, SettingCodable {
    /// Keep hidden panes alive until their web content exceeds the memory
    /// budget, then discard the pane hidden longest, like a Chrome tab discard.
    case memoryBudget = "budget"
    /// Discard every hidden pane once it has been hidden for the delay.
    case timer
}
