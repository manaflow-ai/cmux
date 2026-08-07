@testable import CmuxSudoBroker
import Foundation

struct SudoTestFixture {
    let root: URL
    let paths: SudoBrokerPaths
    let store: SudoSpoolStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sudo-tests-\(UUID().uuidString)", isDirectory: true)
        paths = SudoBrokerPaths(base: root)
        store = SudoSpoolStore(paths: paths)
        try store.ensureDirectories()
    }

    func enqueue(
        id: String,
        createdAt: Date,
        timeoutSeconds: Int = 300,
        requesterIdentity: SudoProcessIdentity? = nil
    ) throws -> SudoRequest {
        let request: SudoRequest
        if let requesterIdentity {
            request = SudoRequest(
                id: id,
                reason: "regression test",
                requesterIdentity: requesterIdentity,
                requesterCommand: "test-agent",
                currentDirectory: "/tmp",
                createdAt: createdAt,
                timeoutSeconds: timeoutSeconds
            )
        } else {
            request = SudoRequest(
                id: id,
                reason: "regression test",
                requesterPid: 123,
                requesterCommand: "test-agent",
                currentDirectory: "/tmp",
                createdAt: createdAt,
                timeoutSeconds: timeoutSeconds
            )
        }
        try store.enqueue(SudoPendingRequest(request: request, script: "echo test\n"))
        return request
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func archivedRequest() throws -> SudoRequest? {
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.archive.path)
        let excludedSuffixes = [".state.json", ".execution.json"]
        guard let name = names.sorted().first(where: { name in
            name.hasSuffix(".json")
                && !excludedSuffixes.contains(where: name.hasSuffix)
        }) else {
            return nil
        }
        let data = try Data(contentsOf: paths.archive.appendingPathComponent(name))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SudoRequest.self, from: data)
    }
}
