public import Foundation

/// The window-side seam `PaneTreeModel` drives when its published stored
/// state changes. The owning `Workspace` is the single implementer.
///
/// **Why synchronous hooks and not an AsyncStream.** These hooks replace the
/// legacy published property observers one-for-one: they fire while the
/// property still holds its old value, and the host re-emits the legacy
/// Combine bridge publishers there at the original timing. A stream would
/// open a suspension window between the mutation and its observers.
///
/// Parity contract: hooks fire on **every** assignment, including
/// assignments of an equal value — the legacy publisher never compared.
@MainActor
public protocol PaneTreeHosting<PanelValue>: AnyObject {
    /// The window's panel type; the app target's `any Panel` existential.
    /// Named `PanelValue` so the binding does not shadow the app's `Panel`
    /// protocol inside the conforming type.
    associatedtype PanelValue

    /// The `panels` map is about to change (legacy `panels`
    /// willSet).
    func panelsWillChange(to newValue: [UUID: PanelValue])
    /// The pane-layout version is about to change (legacy
    /// paneLayoutVersion` willSet).
    func paneLayoutVersionWillChange(to newValue: Int)
}
