import CoreGraphics

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): one look of a ``SidebarStatesPlaygroundSection`` drawn at
/// one column and appearance: the pixels of the part the look shows, and that part's size in points.
struct SidebarStatesPlaygroundLookCell {
    /// The part's pixels; nil when the look showed nothing or drawing failed.
    var image: CGImage?
    /// The part's size, in points.
    var size: CGSize
}
