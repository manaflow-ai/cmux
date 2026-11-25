import AppKit

extension NativePopupRow {
    var isNoninteractive: Bool { kind == .section || kind == .separator || kind == .text }
    /// A submenu, or an action whose levels open beside it (a model row's effort side dropdown):
    /// a click or Return on the action still picks it, its trailing item or Right opens the children.
    var opensChildren: Bool { kind == .submenu || (kind == .action && children?.isEmpty == false) }
    /// `experiments.menuRowStates`: a disabled row's `disabledReason` is its one-line amber caption
    /// (in place of its description), not only its tooltip.
    var showsReasonCaption: Bool {
        disabled == true && disabledReason?.isEmpty == false && DesignSettings.shared.experiment("menuRowStates")
    }
    /// The line under the title: the reason caption, else the description.
    var caption: String? { showsReasonCaption ? disabledReason : description?.isEmpty == false ? description : nil }
    /// `experiments.menuRowStates`: the row's work is running (a spinner in its trailing slot, no pick).
    var isLoading: Bool { loading == true && DesignSettings.shared.experiment("menuRowStates") }
}

extension NSBox {
    static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
}
