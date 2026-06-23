public import Foundation
public import Combine
public import AppKit
public import CmuxCore

/// The behavioral contract every workspace panel (terminal, browser, markdown,
/// file preview, project, agent session, sidebar tool) implements.
///
/// A panel owns one tab's content and its focus lifecycle. Concrete conformers
/// live in the app target because they hold a back-reference to the app-target
/// `Workspace` and drive AppKit/Ghostty/WebKit view hierarchies; the protocol
/// and its value-type vocabulary (``PanelType``, ``PanelFocusIntent``) are the
/// package-pure seam the rest of the app codes against.
///
/// Isolation: `@MainActor`. Every member touches AppKit responders/windows and
/// observable UI state, so the contract lives on the main actor like its
/// callers.
///
/// `ObservableObject` is retained as a faithful lift of the existing protocol
/// shape; the concrete conformers are still `ObservableObject`. Migrating the
/// protocol and conformers to `@Observable` is a separate, behavior-affecting
/// modernization, not part of this byte-identical move.
@MainActor
public protocol Panel: AnyObject, Identifiable, ObservableObject where ID == UUID {
    /// Unique identifier for this panel
    var id: UUID { get }

    /// The type of panel
    var panelType: PanelType { get }

    /// Display title shown in tab bar
    var displayTitle: String { get }

    /// Optional SF Symbol icon name for the tab
    var displayIcon: String? { get }

    /// Whether the panel has unsaved changes
    var isDirty: Bool { get }

    /// Close the panel and clean up resources
    func close()

    /// Focus the panel for input
    func focus()

    /// Unfocus the panel
    func unfocus()

    /// Trigger a focus flash animation for this panel.
    func triggerFlash(reason: WorkspaceAttentionFlashReason)

    /// Capture the panel-local focus target that should be restored later.
    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent

    /// Return the best focus target to restore when this panel becomes active again.
    func preferredFocusIntentForActivation() -> PanelFocusIntent

    /// Prime panel-local focus state before activation side effects run.
    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent)

    /// Restore a previously captured focus target.
    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool

    /// Return the semantic focus target currently owned by this panel, if any.
    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent?

    /// Explicitly yield a previously owned focus target before another panel restores focus.
    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool
}

/// Default implementations shared by every ``Panel`` conformer.
extension Panel {
    public var displayIcon: String? { nil }
    public var isDirty: Bool { false }

    public func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        _ = window
        return preferredFocusIntentForActivation()
    }

    public func preferredFocusIntentForActivation() -> PanelFocusIntent {
        .panel
    }

    public func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        _ = intent
    }

    @discardableResult
    public func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        guard intent == .panel else { return false }
        focus()
        return true
    }

    public func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = responder
        _ = window
        return nil
    }

    @discardableResult
    public func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        _ = intent
        _ = window
        return false
    }

    public func triggerFlash() {
        triggerFlash(reason: .navigation)
    }
}
