import Darwin
import Foundation

struct EmulatorEndpoint: Equatable, Sendable {
    let port: Int
    let bearerToken: String
}

struct EmulatorEndpointLocator: Sendable {
    private let runningDirectoryURL: URL
    private let processMatches: @Sendable (Int32, String, Int, Int) -> Bool

    init(
        runningDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/TemporaryItems/avd/running", isDirectory: true),
        processMatches: @escaping @Sendable (Int32, String, Int, Int) -> Bool = {
            EmulatorProcessIdentity.matches(processID: $0, avdName: $1, consolePort: $2, grpcPort: $3)
        }
    ) {
        self.runningDirectoryURL = runningDirectoryURL
        self.processMatches = processMatches
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
            guard let processID = Self.processID(from: file) else { continue }
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let values = Self.parseINI(contents)
            guard values["avd.name"] == avdName,
                  values["port.serial"] == String(consolePort),
                  let portString = values["grpc.port"],
                  let port = Int(portString),
                  (1 ... 65_535).contains(port),
                  let token = values["grpc.token"], !token.isEmpty,
                  processMatches(processID, avdName, consolePort, port) else { continue }
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

private enum EmulatorProcessIdentity {
    static func matches(processID: Int32, avdName: String, consolePort: Int, grpcPort: Int) -> Bool {
        guard processID > 0, let arguments = commandLineArguments(processID: processID) else { return false }
        let avdMatches = arguments.contains("@\(avdName)") || arguments.indices.contains { index in
            arguments[index] == "-avd"
                && arguments.indices.contains(index + 1)
                && arguments[index + 1] == avdName
        }
        guard avdMatches else { return false }
        if let portIndex = arguments.firstIndex(of: "-port") {
            return arguments.indices.contains(portIndex + 1) && Int(arguments[portIndex + 1]) == consolePort
        }
        if let portsIndex = arguments.firstIndex(of: "-ports") {
            return arguments.indices.contains(portsIndex + 1)
                && arguments[portsIndex + 1].split(separator: ",").first.flatMap { Int(String($0)) } == consolePort
        }
        return listeningTCPPorts(processID: processID)?.contains(grpcPort) == true
    }

    private static func commandLineArguments(processID: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, processID]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let success = buffer.withUnsafeMutableBytes { bytes in
            sysctl(&mib, u_int(mib.count), bytes.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return nil }
        return parseArguments(Array(buffer.prefix(Int(size))))
    }

    private static func parseArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { $0.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size)) }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        skipString(bytes, index: &index)
        skipNulls(bytes, index: &index)
        var arguments: [String] = []
        for _ in 0 ..< argc {
            guard index < bytes.count else { return nil }
            let start = index
            skipString(bytes, index: &index)
            guard let argument = String(bytes: bytes[start ..< index], encoding: .utf8) else { return nil }
            arguments.append(argument)
            if index < bytes.count { index += 1 }
        }
        return arguments
    }

    private static func skipString(_ bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] != 0 { index += 1 }
    }

    private static func skipNulls(_ bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] == 0 { index += 1 }
    }

    private static func listeningTCPPorts(processID: Int32) -> Set<Int>? {
        let requiredBytes = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, nil, 0)
        guard requiredBytes > 0 else { return nil }
        let capacity = Int(requiredBytes) / MemoryLayout<proc_fdinfo>.stride
        guard capacity > 0 else { return nil }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let bytes = proc_pidinfo(
            processID, PROC_PIDLISTFDS, 0, &descriptors,
            Int32(descriptors.count * MemoryLayout<proc_fdinfo>.stride)
        )
        guard bytes > 0 else { return nil }
        return Set(descriptors.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.stride).compactMap { descriptor in
            guard descriptor.proc_fdtype == PROX_FDTYPE_SOCKET else { return nil }
            var socket = socket_fdinfo()
            let socketBytes = proc_pidfdinfo(
                processID, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket,
                Int32(MemoryLayout<socket_fdinfo>.stride)
            )
            guard socketBytes == MemoryLayout<socket_fdinfo>.stride,
                  socket.psi.soi_kind == SOCKINFO_TCP,
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { return nil }
            let networkPort = UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            return Int(UInt16(bigEndian: networkPort))
        })
    }
}
