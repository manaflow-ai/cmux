import Foundation

struct SudoSpoolStore {
    let paths: SudoBrokerPaths
    private let fileManager: FileManager

    init(paths: SudoBrokerPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func ensureDirectories() throws {
        for directory in [
            paths.base, paths.requests, paths.results, paths.states,
            paths.approved, paths.archive, paths.locks,
        ] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    func enqueue(_ pending: SudoPendingRequest) throws {
        try ensureDirectories()
        let scriptURL = paths.requests.appendingPathComponent("\(pending.request.id).sh")
        let requestURL = paths.requests.appendingPathComponent("\(pending.request.id).json")
        try Data(pending.script.utf8).write(to: scriptURL, options: .atomic)
        try Self.encoder.encode(pending.request).write(to: requestURL, options: .atomic)
        try writeState(
            SudoRequestState(
                id: pending.request.id,
                phase: .pendingApproval,
                updatedAt: pending.request.createdAt
            )
        )
    }

    func pendingRequests() -> [SudoPendingRequest] {
        let names = (try? fileManager.contentsOfDirectory(atPath: paths.requests.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let id = String(name.dropLast(5))
            guard result(id: id) == nil,
                  let requestData = try? Data(contentsOf: paths.requests.appendingPathComponent(name)),
                  let request = try? Self.decoder.decode(SudoRequest.self, from: requestData),
                  request.id == id,
                  let script = try? String(
                    contentsOf: paths.requests.appendingPathComponent("\(id).sh"),
                    encoding: .utf8
                  ) else {
                return nil
            }
            return SudoPendingRequest(request: request, script: script)
        }
    }

    func state(id: String) -> SudoRequestState? {
        let url = paths.states.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(SudoRequestState.self, from: data)
    }

    func writeState(_ state: SudoRequestState) throws {
        let url = paths.states.appendingPathComponent("\(state.id).json")
        try Self.encoder.encode(state).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func result(id: String) -> SudoResult? {
        let url = paths.results.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(SudoResult.self, from: data)
    }

    @discardableResult
    func writeResultIfAbsent(_ result: SudoResult) throws -> Bool {
        let url = paths.results.appendingPathComponent("\(result.id).json")
        guard !fileManager.fileExists(atPath: url.path) else { return false }
        try Self.encoder.encode(result).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    func stageApprovedScript(_ script: String, id: String) throws {
        let url = paths.approved.appendingPathComponent("\(id).sh")
        try Data(script.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
