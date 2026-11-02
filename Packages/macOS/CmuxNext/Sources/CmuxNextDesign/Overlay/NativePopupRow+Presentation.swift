import AppKit

extension NativePopupRow {
    var isNoninteractive: Bool { kind == .section || kind == .separator || kind == .text }
}

extension NSBox {
    static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
}
