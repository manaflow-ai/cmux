public import AppKit

/// Feature content inside the standard dialog, sharing its lifetime and keyboard focus trap.
@MainActor
public struct CmuxDialogAccessory {
    public var view: NSView
    public var controls: [NSView]

    /// Controls appear in the dialog's Tab order before its standard fields.
    public init(view: NSView, controls: [NSView]) {
        self.view = view
        self.controls = controls
    }
}
