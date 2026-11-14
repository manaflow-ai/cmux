/// A window's own state as the close-selection rule sees it (`WindowCloseSelection.watch`): its id
/// and the hook it calls at each change of its shown workspace.
public protocol CloseSelectionWindow: AnyObject {
    /// The window's id in the registry.
    var id: String { get }
    /// Called at each change of the shown workspace: the new one, then the one shown before.
    var onShownChange: ((String?, String?) -> Void)? { get set }
}
