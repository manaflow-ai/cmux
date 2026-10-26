import CmuxNextDesign

/// A screen's render-server motion (`ScreenContentView+RenderMotion.swift`).
struct ScreenRenderMotion {
    enum Item: Hashable {
        case pane(PaneID)
        case divider(DividerHandleView.Kind)
    }

    var tracks: [Item: RenderTrack] = [:]
    /// Spring calls that have not landed, plus one while a split adds its springs.
    var inFlight = 0
    /// A frame no track carries was off its rest when the change turn opened: the CPU step moves it.
    var cpuMovedAtTurnStart = false
    /// The open turn's frames took what their tracks show (``RenderTrack/adopt(into:at:)``).
    var adopted = false
    /// The open turn gave the tracked frames back to the CPU step.
    var handedBack = false
}

/// How a change turn left the frames the render server carried.
enum RenderTurnEnd {
    /// No frame was on the render server.
    case untouched
    /// The render server still carries them (the split took the turn, or nothing moved them).
    case carried
    /// The CPU step moves them on from where they show.
    case handedBack
}
