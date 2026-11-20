import CmuxNextDesign

/// The spans that the motion trace (``MotionTrace``, `debug.motion`) gets for the parts of an act's first frame.
///
/// The frame that begins the move of a split, a close, a zoom or an unzoom has work on the main thread beside the
/// move. With the trace on, each part is one span, so a measure of a slow first frame says which part is slow. The
/// spans measure: they take no work away. With the trace off each call here is one Bool check and makes nothing.
/// The work of a terminal's own thread at a new size is in no span.
extension PaneZoomDim {
    enum ActSpan: String {
        /// The motion and the dim read what the screen shows before the change (``layoutWillChange``).
        case arm = "layout.act.arm"
        /// The panes hear the sizes of the change in the key's turn (``ScreenContentView/holdsSnapForContent(keyPress:)``).
        case sizes = "layout.act.sizes"
        /// The layout tells the app each pane whose presence changed, with the app's work for it
        /// (``LayoutViewContext/report(_:)``). This one comes at each such report: a scroll makes one too.
        case report = "layout.act.report"
        /// The pass that shows the change places the pane hosts and the dividers, up to ``panesPlaced(on:)``.
        case pass = "layout.act.pass"
        /// The motion's part of that pass: the copies of the window's picture, the moves, the dim.
        case place = "layout.act.place"
    }

    /// The part `span` begins now, when the trace is on.
    func begins(_ span: ActSpan) {
        if MotionTrace.isEnabled { MotionTrace.begin(span.rawValue) }
    }

    /// The part `span` ends now, when it began.
    func ends(_ span: ActSpan) {
        if MotionTrace.isEnabled { MotionTrace.end(span.rawValue) }
    }

    /// `screen` gives its panes the sizes of the change that waits for its frame, in the key's turn: the motion hears
    /// of it first (``sizesWillChange(on:)``), then each pane that the change resizes hears its size.
    func givesSizes(on screen: ScreenContentView, keyPress: Bool) {
        let acts = motion.waits
        if acts { begins(.sizes) }
        sizesWillChange(on: screen)
        _ = screen.holdsSnapForContent(keyPress: keyPress)
        if acts { ends(.sizes) }
    }

    /// A pass of `screen` begins: it shows the change (``ScreenContentView/beginShowingChange()``), then it places
    /// the panes. Only a pass with a change that waits for its frame gets a span: a scroll's pass of each frame
    /// reads no trace state here.
    func passBegins(on screen: ScreenContentView) {
        if motion.waits { begins(.pass) }
        screen.beginShowingChange()
    }
}
