protocol CommandPaletteEventMonitorSource: AnyObject {
    @MainActor
    func addLocalMouseDownMonitor(
        for window: AnyObject,
        handler: @escaping (CommandPalettePointerEvent) -> Void
    ) -> Any?

    @MainActor
    func removeLocalMonitor(_ monitor: Any)
}
