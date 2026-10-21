import AppKit
import CmuxNextActions

/// Makes each window's file explorer (the right sidebar's Files section) and
/// finds the one an action runs on: the active window's. The tree roots at
/// the focused terminal's folder when it is on this Mac, else the home folder.
@MainActor
final class FileExplorerService {
    private weak var services: AppServices?
    private let sections = NSMapTable<WindowController, FileExplorerSectionView>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    let effects: any FileExplorerEffects
    /// Find tabs (Open Find as Pane).
    private(set) lazy var findPanes = FindPaneService(services: services)

    init(services: AppServices) {
        self.services = services
        effects = AppFileExplorerEffects(services: services)
    }

    /// The Files section of `controller` (made once per window by ``RightSidebarSections``).
    func makeSection(for controller: WindowController) -> FileExplorerSectionView {
        let view = FileExplorerSectionView(
            model: FileExplorerModel(),
            rootFolder: { [weak self, weak controller] in controller.flatMap { self?.folder(focusedIn: $0) } },
            perform: { [weak self] id in self?.perform(ActionID(rawValue: id)) },
            openWith: { [weak self] app in self?.perform("fileExplorerOpenWith", arguments: ["app": .string(app)]) },
            effects: effects,
            showError: { [weak self, weak controller] reason in
                self?.services?.refusalHUD.show(reason, in: controller?.window)
            })
        sections.setObject(view, forKey: controller)
        return view
    }

    /// The Find section of `controller`: ripgrep over the folder the explorer would show.
    func makeFindSection(for controller: WindowController) -> FindSectionView {
        FindSectionView(model: FindSectionModel(), rootFolder: { [weak self, weak controller] in
            controller.flatMap { self?.folder(focusedIn: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        }, effects: effects)
    }

    /// Focus moved in `controller`: its Files tree follows the newly focused terminal's folder.
    func focusChanged(in controller: WindowController) {
        sections.object(forKey: controller)?.follow()
    }

    /// The active window's explorer, once its Files section was shown.
    var activeExplorer: FileExplorerModel? {
        services?.windows.active.flatMap { sections.object(forKey: $0)?.model }
    }

    /// Whether the window's first responder is in a file explorer (`fileExplorerFocused`).
    static func hasKeyboard(_ window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder is FileExplorerTableView || responder.enclosingScrollView?.documentView is FileExplorerTableView
    }

    /// The focused tab's folder when it is a local terminal's.
    func folder(focusedIn controller: WindowController) -> URL? {
        controller.focusedPane.flatMap(folder(of:))
    }

    /// The selected tab's folder of `pane` when it is a local terminal's.
    func folder(of pane: PaneController) -> URL? {
        guard let services, let key = pane.currentTabKey,
              let (tab, model) = services.locateTab(key), services.daemon(for: model).isLocal,
              let cwd = tab.cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd, isDirectory: true)
    }

    /// Runs an explorer action from the explorer itself (a key, a double-click, its menu): the
    /// list has the keyboard, so `fileExplorerFocused` holds for this run.
    private func perform(_ id: ActionID, arguments: [String: ActionValue] = [:]) {
        guard let registry = services?.registry else { return }
        var invocation = ActionInvocation(arguments: arguments)
        invocation.keyContext = registry.context.union(.fileExplorerFocused)
        registry.perform(id, invocation: invocation)
    }
}
