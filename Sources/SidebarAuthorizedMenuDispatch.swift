import AppKit

/// Guards actual AppKit menu callbacks using the original operation's authority.
@MainActor
struct SidebarAuthorizedMenuDispatch {
    let authorization: SidebarActionAuthorization

    func present(_ menu: NSMenu, using presenter: (NSMenu) -> Void) {
        guard authorization.isValid else { return }
        let targets = wrapItems(in: menu)
        withExtendedLifetime(targets) { presenter(menu) }
    }

    private func wrapItems(in menu: NSMenu) -> [SidebarAuthorizedMenuActionTarget] {
        var targets: [SidebarAuthorizedMenuActionTarget] = []
        for item in menu.items {
            if let submenu = item.submenu { targets.append(contentsOf: wrapItems(in: submenu)) }
            guard let action = item.action else { continue }
            let target = SidebarAuthorizedMenuActionTarget(
                authorization: authorization, action: action, target: item.target
            )
            item.target = target
            item.action = #selector(SidebarAuthorizedMenuActionTarget.invokeMenuCommand(_:))
            targets.append(target)
        }
        return targets
    }
}
