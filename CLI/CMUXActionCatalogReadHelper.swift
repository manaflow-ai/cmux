import Foundation

/// Direct, killable filesystem helper for the app's per-cwd action catalog.
/// The CLI intercepts this private command before ordinary socket setup. Paths
/// arrive only as argv values and output uses a bounded binary frame.
struct CMUXActionCatalogReadHelper {
    static let command = "__action-catalog-read-v1"
    static let frameMagic = Data("CMUXCFG1".utf8)
    static let maximumConfigBytes = 4 << 20
    static let maximumPathBytes = 64 << 10

    private let fileManager: FileManager
    private let write: (Data) throws -> Void

    init(
        fileManager: FileManager = .default,
        write: @escaping (Data) throws -> Void = { data in
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    ) {
        self.fileManager = fileManager
        self.write = write
    }

    func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.count > 1, arguments[1] == Self.command else { return nil }
        guard arguments.count == 5,
              let maximumBytes = Int(arguments[4]),
              (1...Self.maximumConfigBytes).contains(maximumBytes) else {
            return 64
        }

        let directory = arguments[2].isEmpty ? nil : arguments[2]
        guard directory.map({ ($0 as NSString).isAbsolutePath }) ?? true,
              (arguments[3] as NSString).isAbsolutePath else {
            return 64
        }

        let localPath = directory.map(resolvedLocalConfigPath(startingFrom:))
        guard localPath.map({ $0.utf8.count <= Self.maximumPathBytes }) ?? true else {
            return 74
        }
        let localPayload = localPath.map {
            readFile(at: $0, maximumBytes: maximumBytes)
        } ?? FilePayload(status: .missing, data: Data())
        let globalPayload = readFile(at: arguments[3], maximumBytes: maximumBytes)

        var frame = Self.frameMagic
        appendField(
            status: localPath == nil ? .missing : .data,
            payload: localPath.map { Data($0.utf8) } ?? Data(),
            to: &frame
        )
        appendField(status: localPayload.status, payload: localPayload.data, to: &frame)
        appendField(status: globalPayload.status, payload: globalPayload.data, to: &frame)
        do {
            try write(frame)
            return 0
        } catch {
            return 74
        }
    }

    private func resolvedLocalConfigPath(startingFrom directory: String) -> String {
        var current = directory
        while true {
            let candidates = [
                ((current as NSString).appendingPathComponent(".cmux") as NSString)
                    .appendingPathComponent("cmux.json"),
                (current as NSString).appendingPathComponent("cmux.json"),
            ]
            if let candidate = candidates.first(where: fileManager.fileExists(atPath:)) {
                return candidate
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return (((directory as NSString).appendingPathComponent(".cmux") as NSString)
            .appendingPathComponent("cmux.json"))
    }

    private func readFile(at path: String, maximumBytes: Int) -> FilePayload {
        guard fileManager.fileExists(atPath: path) else {
            return FilePayload(status: .missing, data: Data())
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return FilePayload(status: .unreadable, data: Data())
        }
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 << 10))
        do {
            while data.count <= maximumBytes {
                let remaining = maximumBytes + 1 - data.count
                guard remaining > 0,
                      let chunk = try handle.read(upToCount: min(remaining, 64 << 10)),
                      !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
        } catch {
            return FilePayload(status: .unreadable, data: Data())
        }
        guard data.count <= maximumBytes else {
            return FilePayload(status: .tooLarge, data: Data())
        }
        return FilePayload(status: .data, data: data)
    }

    private func appendField(status: FieldStatus, payload: Data, to frame: inout Data) {
        frame.append(status.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
    }
}
