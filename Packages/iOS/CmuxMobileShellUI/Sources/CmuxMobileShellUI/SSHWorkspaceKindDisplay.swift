import CmuxMobileShell
import CmuxMobileSupport

// User-facing copy for SSH workspace kinds (PRD D31, D32). Not iOS-only:
// the `+` menu and the terminal picker are shared with the macOS preview.

extension MobileSSHWorkspaceKind {
    /// The `+` menu item that creates a workspace of this kind (PRD D31).
    var sshNewItemTitle: String {
        switch self {
        case .cmuxTUI:
            L10n.string("mobile.ssh.kind.new.cmuxTUI", defaultValue: "New cmux-tui Workspace")
        case .tmux:
            L10n.string("mobile.ssh.kind.new.tmux", defaultValue: "New tmux Session")
        case .shell:
            L10n.string("mobile.ssh.kind.new.shell", defaultValue: "New Shell")
        }
    }

    var sshSystemImage: String {
        switch self {
        case .cmuxTUI: "rectangle.3.group"
        case .tmux: "square.split.2x1"
        case .shell: "terminal"
        }
    }

    var sshAccessibilityKey: String { rawValue }
}

extension MobileSSHTabLayout {
    /// The workspace-level create action: "New Window" (tmux) or "New
    /// Screen" (cmux-tui).
    var newTerminalTitle: String {
        switch kind {
        case .tmux: L10n.string("mobile.ssh.tabs.newWindow", defaultValue: "New Window")
        case .cmuxTUI, .shell: L10n.string("mobile.ssh.tabs.newScreen", defaultValue: "New Screen")
        }
    }

    /// The section-level create action: "Split Pane" on a tmux window,
    /// "New Tab" on a cmux-tui screen.
    var sectionActionTitle: String {
        switch kind {
        case .tmux: L10n.string("mobile.ssh.tabs.splitPane", defaultValue: "Split Pane")
        case .cmuxTUI, .shell: L10n.string("mobile.ssh.tabs.newTab", defaultValue: "New Tab")
        }
    }

    var sectionActionSystemImage: String {
        switch kind {
        case .tmux: "rectangle.split.2x1"
        case .cmuxTUI, .shell: "plus.rectangle.on.rectangle"
        }
    }
}
