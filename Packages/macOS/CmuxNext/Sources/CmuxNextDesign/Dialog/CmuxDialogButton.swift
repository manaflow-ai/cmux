import Foundation

/// One dialog button: its stable id, title, role and Command key.
public nonisolated struct CmuxDialogButton: Equatable, Sendable {
    public enum Role: String, Sendable {
        /// Return presses it; drawn prominent.
        case `default`
        /// Escape presses it.
        case cancel
        /// Drawn in the danger color; never pressed by Return unless it is
        /// also the spec's only default (it is not: roles are exclusive).
        case destructive
        case normal
    }

    /// Stable id reported in the answer and used by automation.
    public var id: String
    public var title: String
    public var role: Role
    /// A lowercase character pressed with Command ("d" for Don't Save).
    public var key: Character?

    public init(id: String, title: String, role: Role = .normal, key: Character? = nil) {
        self.id = id
        self.title = title
        self.role = role
        self.key = key
    }

    public static func ok(_ title: String = CmuxDialogStrings.ok) -> CmuxDialogButton {
        CmuxDialogButton(id: "ok", title: title, role: .default)
    }

    public static func cancel(_ title: String = CmuxDialogStrings.cancel) -> CmuxDialogButton {
        CmuxDialogButton(id: "cancel", title: title, role: .cancel)
    }
}
