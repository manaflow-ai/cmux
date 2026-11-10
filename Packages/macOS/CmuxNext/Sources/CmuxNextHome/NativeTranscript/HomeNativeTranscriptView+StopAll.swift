import MessagesLabHome


/// The stop button's Option-click and tooltip (Stop All Agents, HomeHostView+StopAll).
extension HomeNativeTranscriptView {
    /// The host's Stop all agents, run by Option-click on the stop button; nil
    /// makes Option-click a plain stop.
    public var onStopAll: (() -> Void)? {
        get { transcript.onStopAll }
        set { transcript.onStopAll = newValue }
    }

    /// The stop button's tooltip while the Chief works; nil keeps its label.
    public var stopToolTip: String? {
        get { transcript.stopToolTip }
        set { transcript.stopToolTip = newValue }
    }
}
