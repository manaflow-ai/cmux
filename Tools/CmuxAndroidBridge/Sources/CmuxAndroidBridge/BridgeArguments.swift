import Foundation

struct BridgeArguments: Sendable {
    let avdName: String
    let serial: String
    let socketPath: String
    let sharedMemoryPath: String
    let width: Int
    let height: Int

    static func parse(_ arguments: [String]) throws -> Self {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), arguments.indices.contains(index + 1) else {
                throw BridgeFailure.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let avdName = values["--avd"], !avdName.isEmpty,
              let serial = values["--serial"], !serial.isEmpty,
              let socketPath = values["--socket"], !socketPath.isEmpty,
              let sharedMemoryPath = values["--shared-memory"], !sharedMemoryPath.isEmpty,
              let widthString = values["--width"], let width = Int(widthString), width > 0,
              let heightString = values["--height"], let height = Int(heightString), height > 0 else {
            throw BridgeFailure.invalidArguments
        }
        return Self(
            avdName: avdName,
            serial: serial,
            socketPath: socketPath,
            sharedMemoryPath: sharedMemoryPath,
            width: width,
            height: height
        )
    }
}

enum BridgeFailure: LocalizedError {
    case invalidArguments
    case invalidSerial(String)
    case endpointNotFound(String)
    case invalidSocketPath
    case systemCall(String, Int32)
    case invalidFrame(width: Int, height: Int, bytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Usage: cmux-android-bridge --avd NAME --serial SERIAL --socket PATH --shared-memory PATH --width N --height N"
        case .invalidSerial(let serial): "Invalid emulator serial: \(serial)"
        case .endpointNotFound(let name): "No authenticated gRPC endpoint found for \(name)"
        case .invalidSocketPath: "The Unix socket path is too long"
        case .systemCall(let name, let code): "\(name) failed with errno \(code)"
        case .invalidFrame(let width, let height, let bytes):
            "Invalid \(width)x\(height) RGBA frame containing \(bytes) bytes"
        }
    }
}
