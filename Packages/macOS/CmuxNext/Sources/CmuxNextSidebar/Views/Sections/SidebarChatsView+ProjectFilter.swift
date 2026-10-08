import AppKit
import CmuxNextDesign

// Leo (T3 Code ref, 2026-10-07): once the chats span two projects, a filter
// button (a filter glyph, not a folder) opens a menu of All projects and each
// project with its colored badge. The section's search stays the only search.
extension SidebarChatsView {
    /// The filter menu's first item: no filter.
    public static var allProjectsTitle: String {
        String(localized: "sidebar.chats.allProjects", defaultValue: "All projects", bundle: .module)
    }
    static var filterTitle: String { String(localized: "sidebar.chats.filter", defaultValue: "Filter by project", bundle: .module) }

    /// The chats' projects (folders), distinct, in row order (newest first).
    var projects: [String] {
        var seen = Set<String>()
        return rows.compactMap(\.folder).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Drops a filter whose project left the list, shows the button once there
    /// are two projects, and returns the rows the filter lets through.
    func applyProjectFilter(_ rows: [Row]) -> [Row] {
        let projects = projects
        if let selected = selectedProject, !projects.contains(selected) { selectedProject = nil }
        filterButton.isHidden = projects.count < 2 && selectedProject == nil
        filterButton.symbol = selectedProject == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill"
        filterButton.label = selectedProject.map { SidebarProjectBadge(path: $0).name } ?? Self.filterTitle
        guard let selectedProject else { return rows }
        return rows.filter { $0.folder == selectedProject }
    }

    /// All projects, then each project with its badge; the shown one is checked.
    func projectMenu() -> NSMenu {
        let menu = NSMenu()
        let all = NSMenuItem(title: Self.allProjectsTitle, action: #selector(pickProject(_:)), keyEquivalent: "")
        all.state = selectedProject == nil ? .on : .off
        menu.addItem(all)
        for project in projects {
            let badge = SidebarProjectBadge(path: project)
            let item = NSMenuItem(title: badge.name, action: #selector(pickProject(_:)), keyEquivalent: "")
            item.representedObject = project
            item.image = badge.image()
            item.toolTip = project
            item.state = project == selectedProject ? .on : .off
            menu.addItem(item)
        }
        for item in menu.items { item.target = self }
        return menu
    }

    func showProjectMenu() {
        projectMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: filterButton.bounds.maxY + Metrics.space1), in: filterButton)
    }

    @objc private func pickProject(_ item: NSMenuItem) {
        selectedProject = item.representedObject as? String
        refilter()
    }
}
