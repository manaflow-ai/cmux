import Foundation
import Darwin

extension CMUXCLI {
    func runNextTransportTicket(commandArgs: [String], client: SocketClient) throws {
        let materialArgs = try nextTransportMaterialArguments(commandArgs)
        guard materialArgs.arguments.isEmpty else {
            throw CLIError(message: nextTransportHelp("next-transport-ticket"))
        }
        let response = try client.send(command: "next_transport_ticket")
        try presentNextTransportMaterial(
            response: response, outputURL: materialArgs.outputURL)
    }

    func runNextTransportGrant(commandArgs: [String], client: SocketClient) throws {
        let materialArgs = try nextTransportMaterialArguments(commandArgs)
        let response = try client.send(
            command: "next_transport_grant \(materialArgs.arguments.joined(separator: " "))")
        try presentNextTransportMaterial(
            response: response, outputURL: materialArgs.outputURL)
    }

    struct NextTransportMaterialArguments {
        let arguments: [String]
        let outputURL: URL
    }

    /// Parses the protected handoff option without ever forwarding it to the
    /// socket command as pairing data.
    func nextTransportMaterialArguments(
        _ rawArguments: [String]
    ) throws -> NextTransportMaterialArguments {
        var arguments: [String] = []
        var outputURL: URL?
        var index = 0
        while index < rawArguments.count {
            let argument = rawArguments[index]
            if argument == "--output" {
                guard index + 1 < rawArguments.count,
                    !rawArguments[index + 1].isEmpty
                else {
                    throw CLIError(
                        message: String(
                            localized: "cli.nextTransport.outputUsage",
                            defaultValue: "Usage: add --output <private-file> to receive pairing material."
                        ))
                }
                outputURL = URL(fileURLWithPath: rawArguments[index + 1])
                index += 2
            } else {
                guard !argument.contains(where: \.isWhitespace) else {
                    throw CLIError(
                        message: String(
                            localized: "cli.nextTransport.argumentUsage",
                            defaultValue: "Next-transport identity arguments cannot contain whitespace."
                        ))
                }
                arguments.append(argument)
                index += 1
            }
        }
        guard let outputURL else {
            throw CLIError(
                message: String(
                    localized: "cli.nextTransport.outputUsage",
                    defaultValue: "Usage: add --output <private-file> to receive pairing material."
                ))
        }
        return NextTransportMaterialArguments(arguments: arguments, outputURL: outputURL)
    }

    /// Writes ticket/grant JSON to a caller-selected 0600 file. Pairing
    /// capabilities are intentionally never printed to a terminal or captured
    /// in shell history; errors remain generic and localized.
    func presentNextTransportMaterial(
        response: String, outputURL: URL
    ) throws {
        guard !response.hasPrefix("ERROR:") else {
            throw CLIError(
                message: String(
                    localized: "cli.nextTransport.commandFailed",
                    defaultValue: "Next-transport command failed. Check Debug > Next Transport."
                ))
        }
        guard let data = response.data(using: .utf8) else {
            throw CLIError(
                message: String(
                    localized: "cli.nextTransport.outputWriteFailed",
                    defaultValue: "Unable to write pairing material."
                ))
        }
        do {
            try writePrivateNextTransportMaterial(data, to: outputURL)
        } catch {
            if let error = error as? CLIError { throw error }
            throw CLIError(
                message: String(
                    localized: "cli.nextTransport.outputWriteFailed",
                    defaultValue: "Unable to write pairing material."
                ))
        }
        print(
            String(
                localized: "cli.nextTransport.materialWritten",
                defaultValue: "Pairing material written to \(outputURL.path)."
            ))
    }

    /// Writes through a uniquely-created 0600 temporary file and atomically
    /// renames it into place. Creating the descriptor with its final mode
    /// avoids the world-readable interval that follows `Data.write` before a
    /// later chmod, and `lstat` rejects both live and dangling symlinks.
    private func writePrivateNextTransportMaterial(_ data: Data, to outputURL: URL) throws {
        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(
                "." + outputURL.lastPathComponent + "." + UUID().uuidString + ".tmp")
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw CLIError(
                message: String(
                    localized: "cli.nextTransport.outputWriteFailed",
                    defaultValue: "Unable to write pairing material."
                ))
        }
        var descriptorOpen = true
        var renamed = false
        defer {
            if descriptorOpen { _ = Darwin.close(descriptor) }
            if !renamed { _ = Darwin.unlink(temporaryURL.path) }
        }

        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if written < 0, errno == EINTR {
                continue
            }
            guard written > 0 else {
                throw CLIError(
                    message: String(
                        localized: "cli.nextTransport.outputWriteFailed",
                        defaultValue: "Unable to write pairing material."
                    ))
            }
            offset += written
        }
        let syncResult = Darwin.fsync(descriptor)
        let closeResult = Darwin.close(descriptor)
        descriptorOpen = false
        guard syncResult == 0, closeResult == 0 else {
            throw CLIError(
                message: String(
                    localized: "cli.nextTransport.outputWriteFailed",
                    defaultValue: "Unable to write pairing material."
                ))
        }
        descriptorOpen = false

        var destinationStat = stat()
        if lstat(outputURL.path, &destinationStat) == 0,
            (destinationStat.st_mode & S_IFMT) == S_IFLNK
        {
            throw CLIError(
                message: String(
                    localized: "cli.nextTransport.outputSymlink",
                    defaultValue: "Refusing to write pairing material through a symbolic link."
                ))
        }
        guard rename(temporaryURL.path, outputURL.path) == 0 else {
            throw CLIError(
                message: String(
                    localized: "cli.nextTransport.outputWriteFailed",
                    defaultValue: "Unable to write pairing material."
                ))
        }
        renamed = true
    }

    func nextTransportHelp(_ command: String) -> String {
        switch command {
        case "next-transport-ticket":
            return String(
                localized: "cli.help.nextTransportTicket",
                defaultValue: """
                Usage: cmux next-transport-ticket --output <private-file>

                Write the debug next-transport ticket to a 0600 file. Pairing material is never printed.
                """
            )
        case "next-transport-grant":
            return String(
                localized: "cli.help.nextTransportGrant",
                defaultValue: """
                Usage: cmux next-transport-grant <deviceId> <devicePublicKeyB64> <appIdentity> --output <private-file>

                Write the debug next-transport grant to a 0600 file. Pairing material is never printed.
                """
            )
        default: return ""
        }
    }
}
