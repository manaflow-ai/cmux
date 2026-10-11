import AppKit
import CmuxNextDesign

extension AgentPaneView {
    /// The native sheet a path chip outside the project asks for (D4, `agentPane.links.outsideRoots`
    /// = `confirm`). The sheet is the host's, so page script can never answer it.
    func installReplyLinks() {
        model.replyLinks.confirmOutside = { [weak self] path, answer in
            guard let self, self.window != nil else { return answer(false) }
            let spec = CmuxDialogSpec(title: Self.openOutsideTitle, lines: [path],
                                      buttons: [.cancel(), CmuxDialogButton(id: "open", title: Self.openOutsideButton)])
            // Pane scope: a closed pane ends the sheet as Cancel.
            _ = CmuxDialogCenter.shared.present(spec, in: .tab(self)) { reply in answer(reply.button == "open") }
        }
    }

    static var openOutsideTitle: String {
        String(localized: "agentPane.openOutside.title", defaultValue: "Open a file outside this project?", bundle: .module)
    }

    static var openOutsideButton: String {
        String(localized: "agentPane.openOutside.open", defaultValue: "Open", bundle: .module)
    }
}
