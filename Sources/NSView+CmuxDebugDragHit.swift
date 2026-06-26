#if DEBUG
import AppKit

extension NSView {
    /// Renders this hit-tested view as `<class>@<pointer>{dragTypes=…}` for the
    /// `drag_hit_chain` debug probe (capping the rendered drag-type list at four).
    var cmuxDebugDragHitDescriptor: String {
        let className = String(describing: type(of: self))
        let pointer = String(describing: Unmanaged.passUnretained(self).toOpaque())
        let types = registeredDraggedTypes
        let renderedTypes: String
        if types.isEmpty {
            renderedTypes = "-"
        } else {
            let raw = types.map(\.rawValue)
            renderedTypes = raw.count <= 4
                ? raw.joined(separator: ",")
                : raw.prefix(4).joined(separator: ",") + ",+\(raw.count - 4)"
        }
        return "\(className)@\(pointer){dragTypes=\(renderedTypes)}"
    }
}
#endif
