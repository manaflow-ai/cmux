/// Who made a sidebar document change: the person (a drag, a click, a key, a menu or palette run) or nobody here
/// (auto-archive's pass, an agent's CLI or MCP run, a script, a page, another client). Only the person's own
/// refused change shows why (``SidebarDocStore/onRefused``); the rest is logged.
public nonisolated enum SidebarDocChangeOrigin: String, Sendable {
    case person
    case automatic
}
