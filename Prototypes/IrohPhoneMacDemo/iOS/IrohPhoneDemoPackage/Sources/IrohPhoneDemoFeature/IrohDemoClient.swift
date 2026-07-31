import Foundation
import IrohPhoneMacFFI

public struct IrohPingResult: Equatable, Sendable {
    public let rttMS: Int64
    public let reply: String
    public let remoteID: String
}

public struct IrohTerminalResult: Equatable, Sendable {
    public let rttMS: Int64
    public let output: String
    public let exitCode: Int?
    public let remoteID: String
}

public enum IrohDemoError: LocalizedError, Sendable {
    case missingResponse
    case invalidResponse
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingResponse:
            String(localized: "iroh.demo.error.missingResponse", defaultValue: "The Rust bridge returned no response.", bundle: .module)
        case .invalidResponse:
            String(localized: "iroh.demo.error.invalidResponse", defaultValue: "The Rust bridge returned invalid JSON.", bundle: .module)
        case .requestFailed(let message):
            message
        }
    }
}

public struct IrohDemoClient: Sendable {
    public init() {}

    public func ping(ticket: String, message: String) async -> Result<IrohPingResult, IrohDemoError> {
        await Task.detached(priority: .userInitiated) {
            guard let pointer = iroh_demo_ping(ticket, message) else {
                return .failure(.missingResponse)
            }
            defer {
                iroh_demo_free(pointer)
            }

            let response = String(cString: pointer)
            guard let data = response.data(using: .utf8) else {
                return .failure(.invalidResponse)
            }

            do {
                let payload = try JSONDecoder().decode(IrohPingPayload.self, from: data)
                if payload.ok {
                    return .success(
                        IrohPingResult(
                            rttMS: payload.rttMS ?? 0,
                            reply: payload.reply ?? "",
                            remoteID: payload.remoteID ?? ""
                        )
                    )
                }

                return .failure(
                    .requestFailed(
                        payload.error ?? String(
                            localized: "iroh.demo.error.unknown",
                            defaultValue: "Unknown iroh error",
                            bundle: .module
                        )
                    )
                )
            } catch {
                return .failure(.invalidResponse)
            }
        }.value
    }

    public func terminalCommand(ticket: String, command: String) async -> Result<IrohTerminalResult, IrohDemoError> {
        await Task.detached(priority: .userInitiated) {
            guard let pointer = iroh_demo_terminal_command(ticket, command) else {
                return .failure(.missingResponse)
            }
            defer {
                iroh_demo_free(pointer)
            }

            let response = String(cString: pointer)
            guard let data = response.data(using: .utf8) else {
                return .failure(.invalidResponse)
            }

            do {
                let payload = try JSONDecoder().decode(IrohTerminalPayload.self, from: data)
                if payload.ok {
                    return .success(
                        IrohTerminalResult(
                            rttMS: payload.rttMS ?? 0,
                            output: payload.output ?? "",
                            exitCode: payload.exitCode,
                            remoteID: payload.remoteID ?? ""
                        )
                    )
                }

                return .failure(
                    .requestFailed(
                        payload.error ?? String(
                            localized: "iroh.demo.error.unknown",
                            defaultValue: "Unknown iroh error",
                            bundle: .module
                        )
                    )
                )
            } catch {
                return .failure(.invalidResponse)
            }
        }.value
    }
}

private struct IrohPingPayload: Decodable {
    let ok: Bool
    let rttMS: Int64?
    let reply: String?
    let remoteID: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case rttMS = "rtt_ms"
        case reply
        case remoteID = "remote_id"
        case error
    }
}

private struct IrohTerminalPayload: Decodable {
    let ok: Bool
    let rttMS: Int64?
    let output: String?
    let exitCode: Int?
    let remoteID: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case rttMS = "rtt_ms"
        case output
        case exitCode = "exit_code"
        case remoteID = "remote_id"
        case error
    }
}
