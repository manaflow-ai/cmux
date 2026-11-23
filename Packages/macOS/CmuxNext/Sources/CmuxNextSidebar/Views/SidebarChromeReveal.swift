import CoreGraphics
import CmuxNextDesign

/// The opacity of each piece of the sidebar's hover chrome at one moment: the pointer over the
/// sidebar or not, and the settings that hide pieces until it is.
///
/// By default the New Workspace button, the spaces strip, the profile control and the Search button always
/// show. Minimal Mode (`sidebar.minimal`, user 2026-11-15) or Show Sidebar Controls Only on Hover
/// (`sidebar.controlsOnHover`, Lawrence 2026-10-27 message 14242) shows them only while the pointer is
/// over the sidebar (``SidebarSectionsPreferences/hidesControlsUntilHover``, passed as `controlsOnHover`). `sidebar.spacesVisibility` Always
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
    /// Everything else the sidebar draws that is not its content (``SidebarView/minimalChromeViews``): the cards
    /// (Restart to Update, notices, Now Playing, cmux Updated), the card stack, the Update
    /// Available button, the Priority bell, the titlebar accessory, the needs-you tray, and any view added later.
    /// Only Minimal Mode hides them (user 2026-11-17, msg 38388: "minimal mode should hide everything in sidebar
    /// including cards like update, iff user is not hovered in sidebar"); the older controls-on-hover toggle keeps them.
    var rest: CGFloat

    init(revealed: Bool, minimalMode: SidebarMinimalMode, controlsOnHover: Bool, spacesVisibility: SpacesVisibilityMode,
         minimal: Bool = false) {
        let controls: CGFloat = revealed || !controlsOnHover ? 1 : 0
        newButton = controls
        spaces = revealed || !controlsOnHover || spacesVisibility == .always ? 1 : 0
        topBand = revealed || !minimalMode.hidesTop ? 1 : 0
        bottomBand = revealed || !minimalMode.hidesBottom ? 1 : 0
        footer = min(controls, bottomBand)
        rest = revealed || !minimal ? 1 : 0
    }
}
