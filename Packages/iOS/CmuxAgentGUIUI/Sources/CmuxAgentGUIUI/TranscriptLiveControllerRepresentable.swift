#if os(iOS)
public import CmuxAgentGUIProjection
public import SwiftUI

/// SwiftUI bridge for the production live transcript container.
public struct TranscriptLiveControllerRepresentable: UIViewControllerRepresentable {
    private let input: TranscriptProjectionInput
    private let bottomChromeHeight: CGFloat
    private let theme: AgentGUITheme
    private let terminalThemeGeneration: UInt64

    /// Creates a live transcript bridge.
    /// - Parameters:
    ///   - input: The latest projection input to render.
    ///   - bottomChromeHeight: Height occupied by bottom composer chrome.
    ///   - theme: Agent GUI palette derived from the current terminal theme.
    ///   - terminalThemeGeneration: Observable generation for terminal-theme changes.
    public init(
        input: TranscriptProjectionInput,
        bottomChromeHeight: CGFloat,
        theme: AgentGUITheme,
        terminalThemeGeneration: UInt64
    ) {
        self.input = input
        self.bottomChromeHeight = bottomChromeHeight
        self.theme = theme
        self.terminalThemeGeneration = terminalThemeGeneration
    }

    public func makeUIViewController(context: Context) -> TranscriptLiveContainerViewController {
        let controller = TranscriptLiveContainerViewController(
            theme: theme,
            terminalThemeGeneration: terminalThemeGeneration
        )
        controller.apply(input: input)
        controller.setBottomChromeHeight(bottomChromeHeight)
        return controller
    }

    public func updateUIViewController(
        _ uiViewController: TranscriptLiveContainerViewController,
        context: Context
    ) {
        uiViewController.apply(
            theme: theme,
            terminalThemeGeneration: terminalThemeGeneration
        )
        uiViewController.apply(input: input)
        uiViewController.setBottomChromeHeight(bottomChromeHeight)
    }
}
#endif
