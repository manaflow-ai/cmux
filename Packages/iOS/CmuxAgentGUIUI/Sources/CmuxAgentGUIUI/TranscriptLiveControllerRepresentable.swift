#if os(iOS)
public import CmuxAgentGUIProjection
public import CmuxAgentReplica
public import SwiftUI

/// SwiftUI bridge for the production live transcript container.
public struct TranscriptLiveControllerRepresentable: UIViewControllerRepresentable {
    private let input: TranscriptProjectionInput
    private let bottomChromeHeight: CGFloat
    private let theme: AgentGUITheme
    private let terminalThemeGeneration: UInt64
    private let density: TranscriptDensity
    private let answeringAskID: String?
    private let failedAskID: String?
    private let onAnswer: (PendingAsk, Int) -> Void
    private let onShowTerminal: () -> Void
    private let onShowActivity: (TranscriptActivityDetails) -> Void

    /// Creates a live transcript bridge.
    /// - Parameters:
    ///   - input: The latest projection input to render.
    ///   - bottomChromeHeight: Height occupied by bottom composer chrome.
    ///   - theme: Agent GUI palette derived from the current terminal theme.
    ///   - terminalThemeGeneration: Observable generation for terminal-theme changes.
    ///   - density: Current transcript spacing and metadata-type register.
    public init(
        input: TranscriptProjectionInput,
        bottomChromeHeight: CGFloat,
        theme: AgentGUITheme,
        terminalThemeGeneration: UInt64,
        density: TranscriptDensity,
        answeringAskID: String?,
        failedAskID: String?,
        onAnswer: @escaping (PendingAsk, Int) -> Void,
        onShowTerminal: @escaping () -> Void,
        onShowActivity: @escaping (TranscriptActivityDetails) -> Void = { _ in }
    ) {
        self.input = input
        self.bottomChromeHeight = bottomChromeHeight
        self.theme = theme
        self.terminalThemeGeneration = terminalThemeGeneration
        self.density = density
        self.answeringAskID = answeringAskID
        self.failedAskID = failedAskID
        self.onAnswer = onAnswer
        self.onShowTerminal = onShowTerminal
        self.onShowActivity = onShowActivity
    }

    public func makeUIViewController(context: Context) -> TranscriptLiveContainerViewController {
        let controller = TranscriptLiveContainerViewController(
            theme: theme,
            terminalThemeGeneration: terminalThemeGeneration
        )
        controller.setDensity(density)
        controller.apply(input: input)
        controller.applyPendingAskInteraction(
            answeringAskID: answeringAskID,
            failedAskID: failedAskID,
            onAnswer: onAnswer,
            onShowTerminal: onShowTerminal
        )
        controller.applyActivityPresentation(onShowActivity: onShowActivity)
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
        uiViewController.setDensity(density)
        uiViewController.apply(input: input)
        uiViewController.applyPendingAskInteraction(
            answeringAskID: answeringAskID,
            failedAskID: failedAskID,
            onAnswer: onAnswer,
            onShowTerminal: onShowTerminal
        )
        uiViewController.applyActivityPresentation(onShowActivity: onShowActivity)
        uiViewController.setBottomChromeHeight(bottomChromeHeight)
    }
}
#endif
