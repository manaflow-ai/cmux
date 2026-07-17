import Observation

@available(macOS 15.4, *)
@MainActor
@Observable
final class BrowserWebExtensionActionSnapshotInvalidation {
    var revision = 0

    func refresh() {
        revision &+= 1
    }
}
