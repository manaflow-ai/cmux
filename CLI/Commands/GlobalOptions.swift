import ArgumentParser
import Foundation

struct GlobalOptions: ParsableArguments {
    @Option(name: .customLong("socket"), help: .hidden)
    var socket: String?

    @Option(name: .customLong("password"), help: .hidden)
    var password: String?

    @Option(name: .customLong("window"), help: .hidden)
    var window: String?

    @Flag(name: .customLong("json"))
    var json: Bool = false

    @Option(name: .customLong("id-format"), completion: .list(["refs", "uuids", "both"]))
    var idFormat: String = "refs"

    /// Builds the CLI with the same precedence the hand-rolled parser uses:
    /// --password, then CMUX_SOCKET_PASSWORD, then the password saved in Settings.
    func makeCLI() throws -> CMUXCLI {
        CMUXCLI(
            args: CommandLine.arguments,
            initialSIGPIPEInspectionPayload: CMUXCLI.currentSIGPIPEInspectionPayload()
        )
    }
}
