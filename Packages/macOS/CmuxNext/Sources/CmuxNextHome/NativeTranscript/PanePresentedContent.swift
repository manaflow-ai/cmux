/// Pane tab content that holds a Home transcript, and so reports reads only while a pane on screen
/// presents the tab.
///
/// A ``HomeNativeTranscriptView`` cannot tell from its geometry whether a person sees it: a pane
/// scrolled out of the strip or covered by a docked column keeps its frame, its window and every
/// hidden flag. The layout knows (its pane presence reaches the app's content cache), so the host
/// that owns the transcript's tab sets ``isTabPresented`` and each transcript inside follows it
/// (``HomeNativeTranscriptView/isPresented``). One app path sets it for every conformer: a
/// conversation tab's view, the native Home as a pane tab (`home.tab`) and the docked Home.
/// Content no pane hosts (the Home top page) keeps `true`: its hidden flags and window decide alone.
///
/// ```swift
/// final class TopHomePageView: NSView, PanePresentedContent {
///     var isTabPresented = true {
///         didSet { host?.isTabPresented = isTabPresented }
///     }
/// }
/// ```
@MainActor
public protocol PanePresentedContent: AnyObject {
    /// Whether a pane on screen presents the tab now; every transcript inside follows it, the ones
    /// made later too.
    var isTabPresented: Bool { get set }
}
