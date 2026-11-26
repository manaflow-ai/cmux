import Observation

/// The observation registrar behind `WorkspacesModel`'s tracked members.
///
/// `@Observable` on the generic `WorkspacesModel<Tab>` keyed every read by
/// `\WorkspacesModel<Tab>.member`. The runtime caches a key path only when
/// its type isn't generic, so each read instantiated a new one (demangling
/// the bound generic type, checking its conformance, allocating), and a
/// tracked read then hashed its generic arguments into the access list.
/// Sidebar, overlay and selection code read these members many times per
/// update, and those reads were the innermost frames of the main-thread
/// hangs in #15439.
///
/// This class isn't generic, so its key paths are instantiated once and hash
/// like any other. It holds no values: each member is a `Void` marker the
/// model reports reads and writes against, while the model keeps the values
/// and their property observers.
@MainActor
final class WorkspacesModelObservation: Observable {
    /// Marks reads and writes of `WorkspacesModel.tabs`.
    var tabs: Void { () }

    /// Marks reads and writes of `WorkspacesModel.workspaceGroups`.
    var workspaceGroups: Void { () }

    /// Marks reads and writes of `WorkspacesModel.selectedTabId`.
    var selectedTabId: Void { () }

    private let registrar = ObservationRegistrar()

    /// Records a read of `member` in the active observation tracking, if any.
    func access(_ member: KeyPath<WorkspacesModelObservation, Void>) {
        registrar.access(self, keyPath: member)
    }

    /// Runs `mutation` between the will-set and did-set notifications for
    /// `member`, so tracked reads of it are invalidated before the mutation
    /// and its property observers run.
    func withMutation<Result>(
        of member: KeyPath<WorkspacesModelObservation, Void>,
        _ mutation: () throws -> Result
    ) rethrows -> Result {
        try registrar.withMutation(of: self, keyPath: member, mutation)
    }
}
