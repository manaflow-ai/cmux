import Darwin
import Foundation

/// Resolves bundle metadata for a Simulator process through injected host seams.
struct SimulatorApplicationMetadataResolver {
    typealias ProcessPathResolver = @Sendable (Int32) -> String?

    private let fileManager: FileManager
    private let processPathResolver: ProcessPathResolver

    init(
        fileManager: FileManager = .default,
        processPathResolver: @escaping ProcessPathResolver = simulatorApplicationProcessPath
    ) {
        self.fileManager = fileManager
        self.processPathResolver = processPathResolver
    }

    func bundleURL(processIdentifier: Int32) -> URL? {
        guard processIdentifier > 0,
              let processPath = processPathResolver(processIdentifier)
        else { return nil }
        var current = URL(fileURLWithPath: processPath)
        for _ in 0..<10 {
            if current.pathExtension == "app" { return current }
            let parent = current.deletingLastPathComponent()
            guard parent != current else { break }
            current = parent
        }
        return nil
    }

    func info(bundleURL: URL) -> [String: Any]? {
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL) else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
    }

    func containsReactNative(bundleURL: URL) -> Bool {
        if fileManager.fileExists(
            atPath: bundleURL.appendingPathComponent("main.jsbundle").path
        ) || fileManager.fileExists(
            atPath: bundleURL.appendingPathComponent("Frameworks/React.framework").path
        ) { return true }
        let frameworks = bundleURL.appendingPathComponent("Frameworks")
        let names = (try? fileManager.contentsOfDirectory(atPath: frameworks.path)) ?? []
        return names.contains { name in
            let value = name.lowercased()
            return value.contains("react") || value.contains("hermes") || value.contains("expo")
        }
    }
}

func simulatorApplicationProcessPath(_ processIdentifier: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4_096)
    let length = proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}
