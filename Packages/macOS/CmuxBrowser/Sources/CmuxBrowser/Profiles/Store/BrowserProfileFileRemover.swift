import Foundation

/// Removes profile-owned files via a detached utility task, matching the original
/// best-effort, ignore-errors deletion behavior, conforming to the
/// ``BrowserProfileFileRemoving`` seam.
struct BrowserProfileFileRemover: BrowserProfileFileRemoving {
    func removeItemIfExists(at url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }
}
