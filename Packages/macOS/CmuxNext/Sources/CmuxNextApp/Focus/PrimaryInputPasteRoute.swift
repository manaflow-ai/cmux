import AppKit

/// Red step: the route takes no paste yet (the next commit adds it).
@MainActor
struct PrimaryInputPasteRoute {
    func target(for action: Selector, found: AnyObject?, in window: NSWindow?, input: (any PrimaryInputTarget)?) -> AnyObject? {
        nil
    }
}
