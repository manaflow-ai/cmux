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

    /// Delegates to the legacy runner, which re-parses `CommandLine.arguments`
    /// itself (including --password precedence: --password, then
    /// CMUX_SOCKET_PASSWORD, then the password saved in Settings). The parsed
    /// values on this struct are not passed through; they exist only so
    /// ArgumentParser recognizes and completes the global options.
    func makeCLI() -> CMUXCLI {
        CMUXCLI(
            args: CommandLine.arguments,
            initialSIGPIPEInspectionPayload: CMUXCLI.currentSIGPIPEInspectionPayload()
        )
    }
}
