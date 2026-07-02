#if os(iOS)
import CmuxMobileTerminal

struct TerminalShortcutRowSection: Identifiable {
    let id: String
    let index: Int
    let items: [ResolvedToolbarItem]
}
#endif
