import AppKit
import Foundation

/// Live-state conformance making the running `AppDelegate` the default
/// ``WorkspaceHostEnvironment`` injected into every `Workspace`.
///
/// Every member the protocol requires is a cross-window service a `Workspace`
/// formerly reached through `AppDelegate.shared?.X`. The conformance lives in the
/// app target because the values are app-target types the delegate already owns.
/// All witnesses are satisfied directly by the delegate's existing stored
/// properties (`notificationStore`, `remoteTmuxController`, `tabManager`,
/// `focusLog`) and methods (`tabManagerFor(tabId:)`, `windowId(for:)`,
/// `mainWindow(for:)`, `isCommandPaletteVisible(for:)`, `performCloudVMAction`,
/// `moveBonsplitTabToNewWorkspace`), so this conformance adds no behavior; it
/// only declares that the delegate is the host environment. The behavior the
/// seam routes is therefore byte-identical to the former direct global access.
extension AppDelegate: WorkspaceHostEnvironment {}
