#if DEBUG
import AppKit

extension NSResponder {
    /// Short type name used in file-explorer focus debug logs. Call through
    /// optional chaining so a nil responder logs `"nil"`:
    /// `window.firstResponder?.fileExplorerDebugTypeName ?? "nil"`.
    var fileExplorerDebugTypeName: String {
        String(describing: type(of: self))
    }
}
#endif
