import Foundation
import CmuxPhoneControl

@main
struct CmuxPhoneCommand {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"

        switch command {
        case "help", "--help", "-h":
            printUsage()
        case "self-test":
            try await runSelfTest()
        case "mock-server":
            try await runLineServer(driver: MockPhoneDriver())
        case "wda-server":
            let url = try parseURL(arguments: Array(arguments.dropFirst()))
            let configuration = WebDriverAgentDriver.Configuration(baseURL: url)
            try await runLineServer(driver: WebDriverAgentDriver(configuration: configuration))
        #if canImport(Network)
        case "tcp-self-test":
            try await runTCPClientSelfTest()
        case "tcp-server":
            let serverArguments = Array(arguments.dropFirst())
            let port = try parsePort(arguments: serverArguments)
            let driver = try makeDriver(arguments: serverArguments)
            let server = try PhoneTCPServer(port: port, driver: driver)
            let actualPort = try await server.start()
            print("cmux-phone listening on 127.0.0.1:\(actualPort)")
            dispatchMain()
        #endif
        default:
            throw CLIError.usage("unknown command: \(command)")
        }
    }

    private static func runSelfTest() async throws {
        let server = PhoneControlServer(driver: MockPhoneDriver())
        let list = await server.handle(.request(id: "1", method: "device.list"))
        guard list.first?.type == .response else { throw CLIError.selfTest("device.list") }

        let opened = await server.handle(.request(id: "2", method: "session.open"))
        guard let openResponse = opened.first, let sessionID = openResponse.sessionID else {
            throw CLIError.selfTest("session.open")
        }
        let snapshot = await server.handle(.request(
            id: "3",
            method: "screen.snapshot",
            sessionID: sessionID
        ))
        guard let frame = try snapshot.first?.result?.decode(PhoneScreenFrame.self) else {
            throw CLIError.selfTest("screen.snapshot")
        }
        let tapParams = PhoneJSONValue.object([
            "action_id": .string("self-test-tap"),
            "screen_seq": .number(Double(frame.sequence)),
            "point": .object(["x": .number(0.5), "y": .number(0.5)]),
        ])
        let tap = await server.handle(.request(
            id: "4",
            method: "action.tap",
            sessionID: sessionID,
            params: tapParams
        ))
        guard tap.first?.type == .response, tap.dropFirst().first?.method == "ui.changed" else {
            throw CLIError.selfTest("action.tap")
        }
        let duplicate = await server.handle(.request(
            id: "5",
            method: "action.tap",
            sessionID: sessionID,
            params: .object([
                "action_id": .string("self-test-tap"),
                "screen_seq": .number(Double(frame.sequence)),
                "point": .object(["x": .number(0.5), "y": .number(0.5)]),
            ])
        ))
        guard let receipt = try duplicate.first?.result?.decode(PhoneActionReceipt.self), receipt.duplicate else {
            throw CLIError.selfTest("duplicate action")
        }
        let tree = await server.handle(.request(id: "6", method: "ui.snapshot", sessionID: sessionID))
        guard tree.first?.type == .response else { throw CLIError.selfTest("ui.snapshot") }
        print("{\"ok\":true,\"checks\":[\"device.list\",\"session.open\",\"snapshot\",\"tap\",\"duplicate\",\"ui.snapshot\"]}")
    }

    #if canImport(Network)
    private static func runTCPClientSelfTest() async throws {
        let server = try PhoneTCPServer(port: 0, driver: MockPhoneDriver())
        let port = try await server.start()
        let client = try PhoneControlClient(port: port)

        let devices = try await client.listDevices()
        guard devices.count == 1 else { throw CLIError.selfTest("tcp device.list") }
        let session = try await client.openSession()
        let frame = try await client.snapshot()
        let receipt = try await client.perform(.init(
            actionID: "tcp-self-test-tap",
            kind: .tap,
            screenSequence: frame.sequence,
            point: .init(x: 0.5, y: 0.5)
        ))
        guard receipt.accepted else { throw CLIError.selfTest("tcp action receipt") }
        let event = try await client.nextEvent()
        guard event.method == "ui.changed" else {
            throw CLIError.selfTest("tcp action event")
        }
        try await client.closeSession(sessionID: session.sessionID)
        await client.close()
        server.stop()
        print("{\"ok\":true,\"checks\":[\"tcp device.list\",\"tcp session.open\",\"tcp snapshot\",\"tcp action\",\"tcp close\"]}")
    }
    #endif

    private static func runLineServer(driver: any PhoneDriver) async throws {
        let server = PhoneControlServer(driver: driver)
        var decoder = PhoneLineDecoder(maxLineBytes: PhoneProtocol.maxRequestLineBytes)
        let codec = PhoneWireCodec()
        let input = FileHandle.standardInput
        while let chunk = try input.read(upToCount: PhoneProtocol.maxRequestLineBytes), !chunk.isEmpty {
            let messages = try decoder.append(chunk)
            for message in messages {
                for response in await server.handle(message) {
                    do {
                        try FileHandle.standardOutput.write(contentsOf: codec.encode(response))
                    } catch PhoneWireCodecError.lineTooLarge {
                        let boundedError = PhoneEnvelope.failure(
                            id: response.id,
                            sessionID: response.sessionID,
                            error: PhoneError(
                                code: "response_too_large",
                                message: "the response exceeded the bounded wire size"
                            )
                        )
                        try FileHandle.standardOutput.write(contentsOf: codec.encode(boundedError))
                    }
                }
            }
        }
    }

    private static func parseURL(arguments: [String]) throws -> URL {
        guard let index = arguments.firstIndex(of: "--url"), arguments.indices.contains(index + 1),
              let url = URL(string: arguments[index + 1])
        else { throw CLIError.usage("wda-server requires --url http://127.0.0.1:8100") }
        return url
    }

    private static func parsePort(arguments: [String]) throws -> UInt16 {
        guard let index = arguments.firstIndex(of: "--port"), arguments.indices.contains(index + 1),
              let port = UInt16(arguments[index + 1])
        else { throw CLIError.usage("tcp-server accepts --port PORT (0 chooses an available port)") }
        return port
    }

    private static func makeDriver(arguments: [String]) throws -> any PhoneDriver {
        let source: String
        if let index = arguments.firstIndex(of: "--source"), arguments.indices.contains(index + 1) {
            source = arguments[index + 1]
        } else {
            source = "mock"
        }
        switch source {
        case "mock":
            return MockPhoneDriver()
        case "wda":
            return WebDriverAgentDriver(
                configuration: .init(baseURL: try parseURL(arguments: arguments))
            )
        case "mirroring":
            #if os(macOS)
            return MacIPhoneMirroringDriver()
            #else
            throw CLIError.usage("the mirroring source is only available on macOS")
            #endif
        default:
            throw CLIError.usage("unknown --source \(source); use mock, wda, or mirroring")
        }
    }

    private static func printUsage() {
        print("""
        cmux-phone — local agent control channel for a connected phone

        Commands:
          self-test                 Run a deterministic end-to-end protocol check.
          tcp-self-test             Run the typed client through loopback TCP.
          mock-server               Read newline JSON requests from stdin.
          wda-server --url URL      Use a loopback WebDriverAgent HTTP endpoint.
          tcp-server --port PORT    Serve a source on loopback TCP.
                                    Add --source mock|wda|mirroring.

        The line protocol is versioned as cmux.phone v1. Keep WDA forwarded to
        localhost; it is a developer adapter and must not be exposed on a LAN.
        """)
    }
}

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case selfTest(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        case .selfTest(let check): return "self-test failed at \(check)"
        }
    }
}
