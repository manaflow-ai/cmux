import AppKit
import CmuxNextActions
import CmuxNextFilesUI

/// Makes each window's file explorer (the right sidebar's Files section) and
/// finds the one an action runs on: the right-clicked one for a row's menu (its
/// `explorer` argument), else the active window's. The tree roots at
/// the focused terminal's folder when it is on this Mac, else the home folder.
@MainActor
final class FileExplorerService {
    private weak var services: AppServices?
    private let sections = NSMapTable<WindowController, FileExplorerSectionView>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    /// Each section by the id its row menu passes (`explorer`), so a menu in a back window acts on its own tree.
    private let sectionsByID = NSMapTable<NSString, FileExplorerSectionView>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    /// The argument a row menu's actions carry: the id of the tree it was opened in.
    nonisolated static let explorerArgument = "explorer"
    let effects: any FileExplorerEffects
    /// Find tabs (Open Find as Pane).
    private(set) lazy var findPanes = FindPaneService(services: services)

    init(services: AppServices) {
        self.services = services
        effects = AppFileExplorerEffects(services: services)
    }

    /// The Files section of `controller` (made once per window by ``RightSidebarSections``).
    func makeSection(for controller: WindowController) -> FileExplorerSectionView {
        let id = UUID().uuidString
        let view = FileExplorerSectionView(
            model: FileExplorerModel(),
            rootFolder: { [weak self, weak controller] in controller.flatMap { self?.folder(focusedIn: $0) } },
            perform: { [weak self] id in self?.perform(ActionID(rawValue: id)) },
            rowMenu: { [weak self] hasSelection in self?.rowMenu(hasSelection: hasSelection, explorer: id) },
            openWith: services.map { FileExplorerOpenWithMenu(registry: $0.registry) },
            effects: effects,
            showError: { [weak self, weak controller] reason in
                self?.services?.refusalHUD.show(reason, in: controller?.window)
            })
        sections.setObject(view, forKey: controller)
        sectionsByID.setObject(view, forKey: id as NSString)
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

    /// A Files row's right-click menu: the registry's `fileExplorerRow` menu, only New File and
    /// New Folder (in the root) for the empty area. Its rows run on the tree `explorer` names.
    func rowMenu(hasSelection: Bool, explorer: String? = nil) -> NSMenu? {
        let empty: [ContextMenuEntry] = [.action("fileExplorerNewFile"), .action("fileExplorerNewFolder")]
        let arguments: [String: ActionValue] = explorer.map { [Self.explorerArgument: .string($0)] } ?? [:]
        return services?.registry.makeContextMenu(for: .fileExplorerRow, entries: hasSelection ? nil : empty, arguments: arguments)
    }

    /// The tree `invocation` runs on: the one its `explorer` argument names (a row's menu), else
    /// the active window's. Nil when the named tree is gone.
    func runTarget(for invocation: ActionInvocation) -> FileExplorerRunTarget? {
        let section = if let id = invocation[Self.explorerArgument]?.stringValue {
            sectionsByID.object(forKey: id as NSString)
        } else {
            services?.windows.active.flatMap { sections.object(forKey: $0) }
        }
        return section?.runTarget
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

    /// Runs an explorer action from the explorer itself (a key, a double-click): the list has
    /// the keyboard, so `fileExplorerFocused` holds for this run. Its right-click menu is the
    /// registry's `fileExplorerRow` menu, whose rows imply the same fact.
    private func perform(_ id: ActionID) {
        guard let registry = services?.registry else { return }
        var invocation = ActionInvocation()
        invocation.keyContext = registry.context.union(.fileExplorerFocused)
        registry.perform(id, invocation: invocation)
    }
}
