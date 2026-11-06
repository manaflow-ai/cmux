import AppKit

/// A row control that is made the first time it shows (REOPEN-F7). A workspace row used to make its five hover and
/// content controls (close, more, Unpin, tree fold, audio) with the row and keep them hidden. That is 140 views and
/// their image subviews for 28 rows, laid out before the first frame of a reopened window that shows none of them.
/// Chrome's first paint gives a `display: none` box no layout box. Here a hidden control has no view: the slot makes
/// it, hidden, in the turn that first shows it (the hover's layout or the configure), so it shows in that frame.
///
/// The row stays the one owner of the control's state: `make` reads the row's model, and the row's layout writes
/// `frame` here whether or not the control exists, so a control made later lands where the row last laid it out.
final class RowControlSlot<Host: NSView, Control: NSView> {
    private let make: (Host) -> Control
    private(set) var made: Control?
    /// Where the row's last layout put the control (a made control follows it at once).
    var frame: NSRect = .zero {
        didSet { if let made, made.frame != frame { made.frame = frame } }
    }

    /// `make` gets the row, so the slot holds no reference to it.
    init(_ make: @escaping (Host) -> Control) { self.make = make }

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050).
    nonisolated deinit {}

    /// The control, made hidden at `frame` and added to `host` on its first use.
    func control(in host: Host) -> Control {
        if let made { return made }
        let control = make(host)
        control.isHidden = true
        control.frame = frame
        host.addSubview(control)
        made = control
        return control
    }
}

extension WorkspaceRowView {
    /// `setHoverShown` for a control that exists only once it has shown: showing makes it, hiding one never made does
    /// nothing.
    func setHoverShown<Control: NSView>(_ slot: RowControlSlot<WorkspaceRowView, Control>, _ shown: Bool, fades: Bool) {
        if shown {
            setHoverShown(slot.control(in: self), true, fades: fades)
        } else if let made = slot.made {
            setHoverShown(made, false, fades: fades)
        }
    }
}
