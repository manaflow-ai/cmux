public import Foundation

/// The window-side seam `PaneTreeModel` drives when its published stored
/// state changes. The owning `Workspace` is the single implementer.
///
/// **Why synchronous hooks and not an AsyncStream.** These hooks replace the
/// legacy `@Published` property observers one-for-one: they fire while the
/// property still holds its old value (the host re-emits `objectWillChange`
/// and the legacy Combine bridge publishers there, at the exact timing
/// `@Published` used). A stream would open a suspension window between the
/// mutation and its observers.
///
/// Parity contract: hooks fire on **every** assignment, including
/// assignments of an equal value — `@Published` never compared.
@MainActor
public protocol PaneTreeHosting<PanelValue>: AnyObject {
    /// The window's panel type; the app target's `any Panel` existential.
    /// Named `PanelValue` so the binding does not shadow the app's `Panel`
    /// protocol inside the conforming type.
    associatedtype PanelValue

    /// The `panels` map is about to change (legacy `@Published panels`
    /// willSet).
    func panelsWillChange(to newValue: [UUID: PanelValue])
    /// The pane-layout version is about to change (legacy `@Published
    /// paneLayoutVersion` willSet).
    func paneLayoutVersionWillChange(to newValue: Int)
}
