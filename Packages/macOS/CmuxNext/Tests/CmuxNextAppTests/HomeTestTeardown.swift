import AppKit
import CmuxNextTestSupport
import Testing

extension NSWindow {
    /// A test's teardown for a window that holds Home: closes it and the Chief Settings popover
    /// panels the running test's Homes made. Each `HomeHostView` makes that panel up front and only
    /// ever hides it, and it is no child of the window until it shows, so closing the window leaves
    /// it open (`.closesItsWindows`).
    func closeWithHomePopovers() {
        closeAfterTest()
        guard let test = Test.current else { return }
        let suite = WindowLeaks.suiteKey(of: test.id)
        let name = test.id.nameComponents.dropFirst().joined(separator: ".")
        for panel in WindowLeaks.openWindows(ofSuite: suite)
        where panel.identifier?.rawValue == "cmux.home.chiefSettings" && WindowLeaks.owner(of: panel)?.test == name {
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
    }
}
