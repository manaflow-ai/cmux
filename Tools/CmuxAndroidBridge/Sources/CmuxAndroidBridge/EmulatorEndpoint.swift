import Darwin
import Foundation

struct EmulatorEndpoint: Equatable, Sendable {
    let port: Int
    let bearerToken: String
}

struct EmulatorEndpointLocator: Sendable {
    private let runningDirectoryURL: URL
    private let processIsRunning: @Sendable (Int32) -> Bool

    init(
        runningDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/TemporaryItems/avd/running", isDirectory: true),
        processIsRunning: @escaping @Sendable (Int32) -> Bool = { processID in
            kill(processID, 0) == 0 || errno == EPERM
        }
    ) {
        self.runningDirectoryURL = runningDirectoryURL
        self.processIsRunning = processIsRunning
    }

    func endpoint(avdName: String, serial: String) throws -> EmulatorEndpoint {
        guard serial.hasPrefix("emulator-"),
              let consolePort = Int(serial.dropFirst("emulator-".count)) else {
            throw BridgeFailure.invalidSerial(serial)
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: runningDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasPrefix("pid_") && $0.pathExtension == "ini" }
        for file in files {
            guard let processID = Self.processID(from: file), processIsRunning(processID) else { continue }
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let values = Self.parseINI(contents)
            guard values["avd.name"] == avdName,
                  values["port.serial"] == String(consolePort),
                  let portString = values["grpc.port"],
                  let port = Int(portString),
                  (1 ... 65_535).contains(port),
                  let token = values["grpc.token"], !token.isEmpty else { continue }
            return EmulatorEndpoint(port: port, bearerToken: token)
        }
        throw BridgeFailure.endpointNotFound(avdName)
    }

    private static func processID(from file: URL) -> Int32? {
        let name = file.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("pid_") else { return nil }
        return Int32(name.dropFirst("pid_".count))
    }

    static func parseINI(_ contents: String) -> [String: String] {
        contents.split(whereSeparator: \.isNewline).reduce(into: [:]) { values, line in
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return }
            values[String(pair[0])] = String(pair[1])
        }
    }
}
