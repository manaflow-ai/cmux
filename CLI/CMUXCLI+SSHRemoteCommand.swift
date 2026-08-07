extension CMUXCLI {
    /// Separates OpenSSH terminal configuration from the positional command it launches.
    struct SSHRemoteCommand: Equatable, Sendable {
        enum TTYRequest: Equatable, Sendable {
            case disabled
            case enabled
            case forced

            var argument: String {
                switch self {
                case .disabled: "-T"
                case .enabled: "-t"
                case .forced: "-tt"
                }
            }
        }

        let arguments: [String]
        let ttyRequest: TTYRequest?

        /// OpenSSH accepts leading `-t` and `-T` flags after the destination,
        /// including repeated or clustered forms, until the remote executable
        /// begins. Preserve that boundary before cmux wraps the positional
        /// command in its readiness script.
        init(arguments rawArguments: [String]) {
            var argumentIndex = 0
            var ttyRequest: TTYRequest?
            while argumentIndex < rawArguments.count {
                let argument = rawArguments[argumentIndex]
                guard argument.count > 1,
                      argument.first == "-",
                      argument.dropFirst().allSatisfy({ $0 == "t" || $0 == "T" }) else {
                    self.arguments = Array(rawArguments[argumentIndex...])
                    self.ttyRequest = ttyRequest
                    return
                }
                for flag in argument.dropFirst() {
                    if flag == "T" {
                        ttyRequest = .disabled
                    } else {
                        ttyRequest = ttyRequest == .enabled ? .forced : .enabled
                    }
                }
                argumentIndex += 1
            }
            self.arguments = []
            self.ttyRequest = ttyRequest
        }

        var ttyRequestArguments: [String] {
            ttyRequest.map { [$0.argument] } ?? []
        }
    }
}
