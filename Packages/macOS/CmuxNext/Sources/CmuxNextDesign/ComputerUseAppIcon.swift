public import AppKit
import CmuxNextCompat

/// Computer Use's icon for the rows that ask the person to drag the Computer Use helper into System
/// Settings' Privacy & Security lists: the Computer Use setup's drag row (and its drag image), the
/// setup page's helper image and the agent permission card's tile for the grants the helper holds.
///
/// It is Lucas's midnight cursor tile, the one the composer's @computer-use and the setup window's
/// head draw (`webviews/src/agent-session/acpmux/icons/computerUseTile.png`), as an app icon:
/// `Resources/ComputerUseIcon.icns`, written from the tile by
/// `scripts/cmux-next/generate-computer-use-icon.sh` (9% clear on each side, as the head draws it).
/// The bundled helper carries the same file (bundle-screen-sharing-helper.sh), so System Settings'
/// row shows the tile the drag row showed.
///
/// The rows draw the tile, never the helper bundle's own icon: a helper staged by an older build
/// names no icon (macOS draws the generic blank app) or an older one, and the row must not show it.
public nonisolated struct ComputerUseAppIcon {
    public nonisolated init() {}
    private final class Anchor {}

    /// The bundled Computer Use tile; nil only when the resource bundle is gone.
    public static var tile: NSImage? {
        guard let url = ModuleResourceBundle(cmuxNextTarget: "CmuxNextDesign", anchor: Anchor.self).bundle?
            .url(forResource: "ComputerUseIcon", withExtension: "icns"),
              let data = try? Data(blockingContentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    /// The icon of the Computer Use helper at `appURL`: the tile, else (the resource bundle gone) the
    /// file's own icon.
    public static func image(forApp appURL: URL) -> NSImage {
        tile ?? NSWorkspace.shared.icon(forFile: appURL.path)
    }
}
