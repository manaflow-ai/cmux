import Foundation

extension CloudVMState {
    /// Whether two snapshots describe the same revisioned session content.
    func hasSameRevisionedContent(as other: CloudVMState) -> Bool {
        self == other
    }
}
