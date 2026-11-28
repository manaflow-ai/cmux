/// The start of a live resize's step, before its layout: a window's `setFrame(_:display:)` while it live-resizes, and a
/// divider drag's display-frame tick. Work another component must run before the step lays out goes here: the CEF
/// host runs the message pump work CEF already asked for (`CEFMessagePump.runIfDueAtStep`, `CMUX_NEXT_CEF_PUMP_AT_STEP=1`).
/// A step begun inside the hook's own work (a CEF callback that resizes a view) runs nothing more.
public enum ResizeStepStart {
    /// Runs at the start of every live resize step; nil (the default): nothing does.
    public static var willLayOut: (() -> Void)?

    private static var running = false

    /// A step begins, when `condition` holds (read only while a hook is set): runs ``willLayOut`` once.
    public static func begin(if condition: @autoclosure () -> Bool = true) {
        guard let hook = willLayOut, !running, condition() else { return }
        running = true
        defer { running = false }
        hook()
    }
}
