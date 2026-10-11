public import AppKit

/// A host that keeps dialogs off screen (tests, headless automation): it
/// records what shows, and `closeScope(of:)` acts as if the dialog's tab or
/// window closed.
@MainActor
public final class CmuxDialogHeadlessHost: CmuxDialogHosting {
    public private(set) var shown: [CmuxDialogView] = []
    private var gone: [ObjectIdentifier: () -> Void] = [:]

    public init() {}

    public func show(_ dialog: CmuxDialogView, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {
        shown.append(dialog)
        gone[ObjectIdentifier(dialog)] = scopeGone
    }

    public func hide(_ dialog: CmuxDialogView) {
        shown.removeAll { $0 === dialog }
        gone[ObjectIdentifier(dialog)] = nil
    }

    public func closeScope(of dialog: CmuxDialogView) {
        gone.removeValue(forKey: ObjectIdentifier(dialog))?()
    }
}
