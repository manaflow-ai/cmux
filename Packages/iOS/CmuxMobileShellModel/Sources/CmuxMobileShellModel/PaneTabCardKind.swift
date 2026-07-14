public import CMUXMobileCore

/// The client-visible kind of one pane strip card.
public enum PaneTabCardKind: Equatable, Sendable {
    /// A mirrored Mac terminal tab.
    case terminal
    /// A view-only mirrored Mac browser tab.
    case mirroredBrowser
    /// The workspace's phone-local interactive browser.
    case localBrowser
    /// A phone-rendered agent-chat session bound to a terminal.
    case agentChat

    /// Maps a Mac topology tab kind to its client-visible card kind.
    /// - Parameter kind: The Mac-authored topology kind.
    public init(mirrored kind: MobileWorkspaceTabKind) {
        switch kind {
        case .terminal: self = .terminal
        case .browser: self = .mirroredBrowser
        }
    }
}
