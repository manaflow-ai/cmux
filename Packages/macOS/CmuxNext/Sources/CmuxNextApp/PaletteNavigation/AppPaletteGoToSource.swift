import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextPalette
import Foundation

/// The Open and Ask Agent rows of Cmd-P and Cmd-Shift-P for a typed path or
/// web address, over the active window's focused pane. Each takes the path
/// its other entrypoints take: a file the file pages (`ViewerService`), a
/// folder a new terminal tab (New Terminal Tab), a web address `openBrowser`
/// (New Browser Tab, the default engine), Ask Agent a new agent tab with a
/// seed (as the Feed's Start Agent).
final class AppPaletteGoToSource: PaletteGoToSource {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    private var pane: PaneController? { services?.windows.active?.focusedPane }

    func baseDirectory() -> String? {
        pane.flatMap(ViewerService.folder(of:))
    }

    func open(_ target: PaletteQueryTarget) {
        guard let services else { return }
        guard let pane else { return services.registry.refuse(MiscHandlerStrings.noPane) }
        switch target {
        case .file(let url):
            services.viewers.openFile(url, in: pane, markdown: false)
        case .folder(let url):
            pane.newTerminalTab(cwd: url.path)
        case .web(let url):
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.paneKey),
                                              arguments: ["url": .string(url.absoluteString)], origin: .user)
            _ = services.registry.perform(.openBrowser, invocation: invocation)
        }
    }

    func askAgent(about target: PaletteQueryTarget, prompt: String?) {
        guard let services else { return }
        guard let pane else { return services.registry.refuse(MiscHandlerStrings.noPane) }
        let text = target.agentText(prompt: prompt)
        // The user's own words go out at once (a person's action); the bare place waits in the composer.
        let seed = prompt == nil
            ? AgentPaneSeed(cwd: target.workingDirectory, draft: text)
            : AgentPaneSeed(cwd: target.workingDirectory, prompt: text, promptBy: .person)
        _ = pane.openAgentTab(seed: AgentPaneSeedSource(seed))
    }
}
