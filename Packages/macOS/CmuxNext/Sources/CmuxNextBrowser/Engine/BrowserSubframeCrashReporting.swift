/// Pages whose engine tells when a frame of the page crashed in a renderer other than its main
/// frame's (an out-of-process iframe): the page itself lives on, with a sad frame in it. Chromium tabs
/// report it; WebKit keeps every frame of a page in one process, whose end is the page's own.
@MainActor public protocol BrowserSubframeCrashReporting: AnyObject {
    /// Runs on the main actor each time a frame of this page outside its main frame's renderer
    /// crashes; set by the page's owner (the app's browser hibernation), nil reports nothing. The
    /// page reads which renderers host its frames only while this is set.
    var onSubframeCrash: (@MainActor () -> Void)? { get set }
}
