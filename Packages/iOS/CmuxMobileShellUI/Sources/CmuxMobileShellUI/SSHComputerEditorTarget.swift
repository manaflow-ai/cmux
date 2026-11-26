import Foundation

/// Which SSH computer the add/edit form targets.
enum SSHComputerEditorTarget: Hashable {
    case new
    case edit(UUID)

    var hostID: UUID? {
        if case .edit(let id) = self { return id }
        return nil
    }
}
