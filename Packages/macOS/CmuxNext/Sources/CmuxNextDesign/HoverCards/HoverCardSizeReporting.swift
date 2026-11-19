public import AppKit

/// A body that knows its own fitting size (Show details and Hide details of the sidebar's workspace card): the panel
/// takes that size instead of measuring the card's content with `fittingSize`, whose temporary layout engine was most of
/// a details press's main-thread work (58% in a sampled profile on cmux-lawrence-2, Lawrence 2026-11-18).
@MainActor
public protocol HoverCardSizeReporting: AnyObject {
    /// The body's fitting size in the state it is in now, or nil: the panel measures it.
    var reportedFittingSize: CGSize? { get }
    /// The card rests: the body may measure the sizes a next change will ask for (after this frame's commit, off any
    /// press).
    func prepareSizes()
}
