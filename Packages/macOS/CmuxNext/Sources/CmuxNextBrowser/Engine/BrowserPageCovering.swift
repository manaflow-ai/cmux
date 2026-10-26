/// Tabs whose page draws in its own child window over the cmux window (`.childWindow`), which no view order puts a
/// view in front of: a view that must show in the page's place gets it through a hole over the whole page.
@MainActor
public protocol BrowserPageCovering: AnyObject {
    /// True while a view in the pane shows in the page's place (a launch picture, `BrowserLaunchPictureView`): the
    /// page window has a hole over all of the page, and the mouse goes to the cmux window there.
    var isPageCovered: Bool { get set }
}
