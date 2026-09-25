import CmuxFoundation
import Foundation
import Observation

/// Projects the CLI's validated ledger into immutable values for the native pane.
@MainActor @Observable
final class ReviewPaneModel {
    private let commands: any CommandRunning
    private let cliPath: String
    private var generation = UUID()
    private(set) var runs: [ReviewRunItem] = []
    private(set) var findings: [ReviewFindingItem] = []
    private(set) var intent = ""
    private(set) var source = ""
    private(set) var error: String?
    private(set) var isLoading = false

    init(commands: any CommandRunning, cliPath: String) {
        self.commands = commands
        self.cliPath = cliPath
    }

    func load(directory: String?, selection: String, includeAll: Bool) async {
        let request = UUID()
        generation = request
        runs = []
        findings = []
        intent = ""
        source = ""
        error = nil
        isLoading = false
        guard let directory, !directory.isEmpty else { return }
        isLoading = true
        defer { if generation == request { isLoading = false } }
        do {
            let list = try await read(["list"], directory: directory)
            guard generation == request, !Task.isCancelled else { return }
            let rows = list["reviews"] as? [[String: Any]] ?? []
            runs = rows.compactMap { row in
                guard let id = row["id"] as? String, let created = row["created_at"] as? String else { return nil }
                return ReviewRunItem(id: id, createdAt: created)
            }
            guard !runs.isEmpty else { return }
            let selected = runs.contains(where: { $0.id == selection }) ? selection : runs[0].id
            let receipt = try await read(["show", selected], directory: directory)
            let result = try await read(["findings", selected] + (includeAll ? ["--all"] : []), directory: directory)
            guard generation == request, !Task.isCancelled else { return }
            let brief = receipt["brief"] as? [String: Any] ?? [:]
            intent = brief["intent"] as? String ?? ""
            let coordinate = receipt["source"] as? [String: Any] ?? [:]
            source = (coordinate["tree_sha"] as? String) ?? ""
            findings = (result["findings"] as? [[String: Any]] ?? []).compactMap(ReviewFindingItem.init)
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func read(_ arguments: [String], directory: String) async throws -> [String: Any] {
        let result = await commands.run(
            directory: directory,
            executable: cliPath,
            arguments: ["review"] + arguments + ["--repo", directory, "--json"],
            timeout: 15
        )
        try Task.checkCancellation()
        guard result.exitStatus == 0, !result.timedOut, result.executionError == nil,
              let text = result.stdout,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw NSError(domain: "cmux.review", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "review.pane.loadFailed", defaultValue: "Unable to load the review ledger.")
            ])
        }
        return object
    }
}
