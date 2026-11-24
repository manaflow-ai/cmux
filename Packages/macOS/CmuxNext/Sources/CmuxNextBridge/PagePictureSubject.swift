public import CoreGraphics

/// A page tab's view as ``PageTabPictures`` pictures it: Markdown, a file viewer, a diff, Settings.
///
/// The app's page tab view conforms; a test passes a fake.
@MainActor
public protocol PagePictureSubject: AnyObject {
    /// The key its picture is kept under (the tab's provider key).
    var pictureKey: String { get }
    /// Counts the times the page came on screen; a picture taken at an older count may no longer
    /// be what the page shows.
    var shownGeneration: Int { get }
    /// The theme the page draws in now (its effective appearance's name). A picture taken in another
    /// theme no longer stands for the page: the light card showed a dark page (capture of 2026-11-11).
    /// Read at ask time, it is right whichever view hears of a theme change first.
    var pictureLook: String { get }
    /// Whether the page is on screen now (in a window, not parked behind another tab).
    var isOnScreen: Bool { get }
    /// A picture of the page as it last drew, at most `maxPixelWidth` pixels wide, its clear areas
    /// kept clear; nil when it has none (a native page).
    func picture(maxPixelWidth: CGFloat) async -> CGImage?
}
