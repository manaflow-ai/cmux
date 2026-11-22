import AppKit

extension NativePopupRow {
    var isNoninteractive: Bool { kind == .section || kind == .separator || kind == .text }
    /// A submenu, or an action whose levels open beside it (a model row's effort side dropdown):
    /// a click or Return on the action still picks it, its trailing item or Right opens the children.
    var opensChildren: Bool { kind == .submenu || (kind == .action && children?.isEmpty == false) }
}

extension NSBox {
    static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
}
