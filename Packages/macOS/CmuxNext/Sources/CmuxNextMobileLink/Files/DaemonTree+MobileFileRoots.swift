public import CmuxMobileHost
public import CmuxNextDaemon
import Foundation

/// Each workspace's directory as the phone may reach it (c4-files.md 3): the
/// presented directory of the workspace's first local terminal (OSC 7, else
/// its launch directory), one root per workspace, keyed by its `ws_…` id.
/// `MobileFilePolicy` still drops roots that are home, above home or
/// protected. Pure.
extension DaemonTree {
    public var mobileFileRoots: [MobileFileRoot] {
        var roots: [MobileFileRoot] = []
        for workspace in workspaces where !workspace.isHome {
            guard let id = workspace.resourceID?.rawValue else { continue }
            let tabs = workspace.screens.flatMap(\.panes).filter { !$0.dead }.flatMap(\.tabs)
            guard let cwd = tabs.first(where: { $0.kind == .pty && !$0.dead && ($0.cwd?.hasPrefix("/") ?? false) })?.cwd else {
                continue
            }
            roots.append(MobileFileRoot(id: id, name: workspace.displayName, url: URL(fileURLWithPath: cwd, isDirectory: true),
                                        writable: true))
        }
        return roots
    }
}
