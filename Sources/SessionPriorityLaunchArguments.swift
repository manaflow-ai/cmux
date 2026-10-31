/// Reads and rewrites one option in a recorded agent launch argv.
///
/// `argv[0]` is the executable and is never read as an option. Scanning stops at a `--`
/// terminator: what follows is a prompt, which a resume drops.
enum SessionPriorityLaunchArguments {
    /// The value of the last `option value` or `option=value` in `arguments`, or `nil` when the
    /// option is absent or has no value.
    static func value(ofOption option: String, in arguments: [String]) -> String? {
        let equalsPrefix = option + "="
        var value: String?
        var index = 1
        while index < arguments.count, arguments[index] != "--" {
            let argument = arguments[index]
            if argument == option {
                value = index + 1 < arguments.count ? arguments[index + 1] : nil
                index += 2
                continue
            }
            if argument.hasPrefix(equalsPrefix) {
                value = String(argument.dropFirst(equalsPrefix.count))
            }
            index += 1
        }
        return value
    }

    /// `arguments` with every `option value` and `option=value` removed and `option value`
    /// added once, after the other options and before a `--` terminator. Unchanged when
    /// `arguments` has no `argv[0]` to add the option to.
    static func replacing(option: String, with value: String, in arguments: [String]) -> [String] {
        guard let executable = arguments.first else { return arguments }
        let equalsPrefix = option + "="
        var options: [String] = []
        var index = 1
        while index < arguments.count, arguments[index] != "--" {
            let argument = arguments[index]
            if argument == option {
                index += 2
                continue
            }
            if !argument.hasPrefix(equalsPrefix) {
                options.append(argument)
            }
            index += 1
        }
        let terminatedTail = index < arguments.count ? Array(arguments[index...]) : []
        return [executable] + options + [option, value] + terminatedTail
    }
}
