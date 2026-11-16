public import CmuxNextSidebar
import CmuxNextDesign

extension SidebarMapping {
    /// A machine's icon (`session-icon-v1`: its record's `icon` in the home
    /// session registry) as its sidebar header and hover card draw it: an
    /// emoji or SF Symbol as itself, a stored image or SVG once `asset` has
    /// read it. For no icon, a value that is no icon, or an asset not read
    /// yet: `device`, the SF Symbol of the device the machine is (its daemon's
    /// `machine_symbol`, cmux-device-kind), else nil, so the machine's own
    /// symbol draws until the image arrives.
    public static func machineIcon(_ value: String?, asset: (String) -> SidebarFavicon? = { _ in nil }, device: String? = nil) -> WorkspaceIcon? {
        let fallback: WorkspaceIcon? = device.map { .symbol($0) }
        guard let value else { return fallback }
        if let image = asset(value) { return .favicon(image) }
        switch IconValue(wire: value) {
        case .emoji(let text)?: return .emoji(text)
        case .symbol(let name)?: return .symbol(name)
        case .image?, .svg?, nil: return fallback
        }
    }
}
