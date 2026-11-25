public import Foundation

/// A section of the Sidebar States Playground that another package draws (DEV and NIGHTLY, Debug menu > Sidebar
/// States Playground): a title and its looks, each drawn at every density and text size, in light and dark.
///
/// The sidebar package draws only its own rows. A look of another domain (the Home list's filter, which lives in
/// `CmuxNextHome`) comes in from the composition root as a section, so this package never imports that domain.
///
/// ```swift
/// SidebarStatesPlaygroundSection(title: "Home filter", looks: [
///     SidebarStatesPlaygroundLook(title: "Unread filter off") { root in
///         let home = HomeSidebarView(frame: root.bounds)
///         root.addSubview(home)
///         return root.convert(home.filterParts().toggle, from: home)
///     },
/// ])
/// ```
public struct SidebarStatesPlaygroundSection {
    /// The section's sheet title, before the appearance ("Home filter · Dark").
    public var title: String
    /// The section's rows, top to bottom.
    public var looks: [SidebarStatesPlaygroundLook]

    /// Creates a section.
    /// - Parameters:
    ///   - title: The section's sheet title, before the appearance.
    ///   - looks: The section's rows, top to bottom.
    public init(title: String, looks: [SidebarStatesPlaygroundLook]) {
        self.title = title
        self.looks = looks
    }
}
