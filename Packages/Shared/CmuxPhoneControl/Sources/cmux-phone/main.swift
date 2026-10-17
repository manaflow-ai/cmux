import Foundation
import CmuxPhoneControl

@main
struct CmuxPhoneCommand {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"

        do {
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
            default:
                throw CLIError.usage("unknown command: \(command)")
            }
        } catch {
            fputs("cmux-phone: \(error)\n", stderr)
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

    private static func runLineServer(driver: any PhoneDriver) async throws {
        let server = PhoneControlServer(driver: driver)
        var decoder = PhoneLineDecoder()
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let messages = try decoder.append(input)
        let codec = PhoneWireCodec()
        var output = Data()
        for message in messages {
            for response in await server.handle(message) {
                output.append(try codec.encode(response))
            }
        }
        try FileHandle.standardOutput.write(contentsOf: output)
    }

    private static func parseURL(arguments: [String]) throws -> URL {
        guard let index = arguments.firstIndex(of: "--url"), arguments.indices.contains(index + 1),
              let url = URL(string: arguments[index + 1])
        else { throw CLIError.usage("wda-server requires --url http://127.0.0.1:8100") }
        return url
    }

    private static func printUsage() {
        print("""
        cmux-phone — local agent control channel for a connected phone

        Commands:
          self-test                 Run a deterministic end-to-end protocol check.
          mock-server               Read newline JSON requests from stdin.
          wda-server --url URL      Use a loopback WebDriverAgent HTTP endpoint.

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
