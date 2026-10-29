public import AppKit
public import CmuxNextWakeups

extension WindowOcclusionChecker {
    /// A started checker of every window that has a ``WindowOcclusionFamily``, which tells each family
    /// when its window goes off screen and comes back (feature `windowOcclusionFamily`).
    /// It is Chrome's checker pass (``WindowOcclusionRule``, web_contents_occlusion_checker_mac.mm):
    /// AppKit's state, or one opaque cmux window in front covering the window, the same-size case
    /// AppKit does not report (crbug.com/883031). A new window joins at the next pass, which its
    /// ordering in or becoming main starts. The caller keeps the checker for the app's lifetime.
    ///
    /// - Parameters:
    ///   - windows: The app's windows; the ones with a family are judged (tests pass their own).
    ///   - orderedWindows: The app's windows front to back.
    ///   - facts: Reads a window's facts (tests describe windows without a screen).
    ///   - isAppHidden: Whether the app is hidden now.
    ///   - drawsWhenOccluded: Automation launches keep occluded windows drawing: no family is occluded.
    ///   - center: Window and application notifications.
    ///   - workspaceEvents: The displays' sleep and wake: the app's events of NSWorkspace's center.
    ///   - mainWork: The app's main-thread scheduler, where the coalesced pass is posted.
    /// - Returns: The checker, already started.
    public static func feedingFamilies(windows: @escaping @MainActor () -> [NSWindow] = { NSApp?.windows ?? [] },
                                       orderedWindows: @escaping @MainActor () -> [NSWindow] = { NSApp?.orderedWindows ?? [] },
                                       facts: @escaping @MainActor (NSWindow) -> WindowOcclusionFacts = WindowDrawPolicy.occlusionFacts(of:),
                                       isAppHidden: @escaping @MainActor () -> Bool = { NSApp?.isHidden ?? false },
                                       drawsWhenOccluded: Bool = WindowDrawPolicy.drawsWhenOccluded,
                                       center: NotificationCenter = .default, workspaceEvents: AppEvents,
                                       mainWork: MainWorkScheduler) -> WindowOcclusionChecker {
        let tracked: @MainActor () -> [NSWindow] = { windows().filter { WindowOcclusionFamily.installed(on: $0) != nil } }
        let checker = WindowOcclusionChecker(windows: tracked, orderedWindows: orderedWindows, facts: facts, isAppHidden: isAppHidden,
                                             drawsWhenOccluded: drawsWhenOccluded, center: center, workspaceEvents: workspaceEvents,
                                             mainWork: mainWork)
        let report: @MainActor (ObjectIdentifier, Bool) -> Void = { id, offScreen in
            let window = tracked().first { ObjectIdentifier($0) == id }
            window.flatMap(WindowOcclusionFamily.installed(on:))?.set(occluded: offScreen)
        }
        checker.onChange = { id, offScreen in report(id, offScreen) }
        // The checker forgets a closing window: its family starts unoccluded if the window shows again.
        checker.onClose = { id in report(id, false) }
        checker.start()
        return checker
    }
}
