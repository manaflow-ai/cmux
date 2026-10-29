import CoreGraphics
import CmuxNextDesign

/// The opacity of each piece of the sidebar's hover chrome at one moment: the pointer over the
/// sidebar or not, and the settings that hide pieces until it is.
///
/// Show Sidebar Controls Only on Hover (`sidebar.controlsOnHover`, Lawrence 2026-10-27 message 14242) is off by default,
/// so the New Workspace button, the spaces strip, the profile control and the Search button always
/// show. On, they show only while the pointer is over the sidebar. `sidebar.spacesVisibility` Always
/// keeps the strip shown even then. Hide Bands Until Hover (`sidebar.minimalMode`) still hides its
/// bands. Every piece is a fade only: it keeps its frame and its place in the accessibility tree.
struct SidebarChromeReveal: Equatable {
    /// The titlebar row's New Workspace button.
    var newButton: CGFloat
    /// The spaces strip.
    var spaces: CGFloat
    /// The band above the list.
    var topBand: CGFloat
    /// The band below the list.
    var bottomBand: CGFloat
    /// The pinned footer row: the profile control and the Search button.
    var footer: CGFloat

    init(revealed: Bool, minimalMode: SidebarMinimalMode, controlsOnHover: Bool, spacesVisibility: SpacesVisibilityMode) {
        let controls: CGFloat = revealed || !controlsOnHover ? 1 : 0
        newButton = controls
        spaces = revealed || !controlsOnHover || spacesVisibility == .always ? 1 : 0
        topBand = revealed || !minimalMode.hidesTop ? 1 : 0
        bottomBand = revealed || !minimalMode.hidesBottom ? 1 : 0
        footer = min(controls, bottomBand)
    }
}
