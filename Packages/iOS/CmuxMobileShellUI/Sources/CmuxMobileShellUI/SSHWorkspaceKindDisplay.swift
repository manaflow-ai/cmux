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
}

extension MobileSSHSectionAction {
    /// The section-level create action's menu title. The splits reuse the
    /// cmux macOS action names ("Split Right", "Split Down").
    var title: String {
        switch self {
        case .newTab: L10n.string("mobile.ssh.tabs.newTab", defaultValue: "New Tab")
        case .splitRight: L10n.string("mobile.ssh.tabs.splitRight", defaultValue: "Split Right")
        case .splitDown: L10n.string("mobile.ssh.tabs.splitDown", defaultValue: "Split Down")
        }
    }

    /// The split glyphs match the cmux macOS tab-bar split actions.
    var systemImage: String {
        switch self {
        case .newTab: "plus.rectangle.on.rectangle"
        case .splitRight: "square.split.2x1"
        case .splitDown: "square.split.1x2"
        }
    }

    /// `MobileSSHSectionAction-<action>-<section>`, unique per menu item.
    func accessibilityIdentifier(section: String) -> String {
        "MobileSSHSectionAction-\(rawValue)-\(section)"
    }
}
