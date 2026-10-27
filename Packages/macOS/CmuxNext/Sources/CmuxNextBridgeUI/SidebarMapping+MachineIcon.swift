public import CmuxNextBridge
public import CmuxNextSidebar
import CmuxNextDesign

extension SidebarMapping {
    /// A machine's icon (`session-icon-v1`: its record's `icon` in the home
    /// session registry) as its sidebar header and hover card draw it: an
    /// emoji or SF Symbol as itself, a stored image or SVG once `asset` has
    /// read it. Nil for no icon, a value that is no icon, or an asset not
    /// read yet, so the machine's own symbol draws until the image arrives.
    public static func machineIcon(_ value: String?, asset: (String) -> SidebarFavicon? = { _ in nil }) -> WorkspaceIcon? {
        guard let value else { return nil }
        if let image = asset(value) { return .favicon(image) }
        switch IconValue(wire: value) {
        case .emoji(let text)?: return .emoji(text)
        case .symbol(let name)?: return .symbol(name)
        case .image?, .svg?, nil: return nil
        }
    }
}
