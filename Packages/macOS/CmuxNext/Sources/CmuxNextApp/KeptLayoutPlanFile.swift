import CmuxNextDaemon
import Foundation

/// `<Application Support>/<bundle id>/kept-layout.json`: the plan End
/// Sessions, Keep Layout writes for the next launch.
nonisolated struct KeptLayoutPlanFile: Sendable {
    let url: URL

    static func forApplication(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> KeptLayoutPlanFile {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return KeptLayoutPlanFile(url: support.appending(path: bundle).appending(path: "kept-layout.json"))
    }

    /// File IO runs off the main actor.
    func write(_ plan: KeptLayoutPlan) async {
        let url = url
        await Task.detached(priority: .userInitiated) {
            guard let data = try? JSONEncoder().encode(plan) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }.value
    }

    func read() async -> KeptLayoutPlan? {
        let url = url
        return await Task.detached(priority: .userInitiated) { () -> KeptLayoutPlan? in
            // concurrency-allow: runs in a detached task, off the main actor
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(KeptLayoutPlan.self, from: data)
        }.value
    }

    func remove() async {
        let url = url
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }.value
    }
}
