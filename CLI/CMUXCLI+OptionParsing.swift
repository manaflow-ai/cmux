import Foundation

/// Shared per-command flag/option parsing helpers, extracted verbatim from
/// `cmux.swift` (which may not grow). All of them stop interpreting flags at
/// the `--` terminator so forwarded arguments pass through untouched.
extension CMUXCLI {
    func parseOption(_ args: [String], name: String) -> (String?, [String]) {
        var remaining: [String] = []
        var value: String?
        var skipNext = false
        var pastTerminator = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, arg.hasPrefix("\(name)=") {
                value = String(arg.dropFirst(name.count + 1))
                continue
            }
            if !pastTerminator, arg == name, idx + 1 < args.count {
                value = args[idx + 1]
                skipNext = true
                continue
            }
            remaining.append(arg)
        }
        return (value, remaining)
    }

    func parseRepeatedOption(_ args: [String], name: String) -> ([String], [String]) {
        var remaining: [String] = []
        var values: [String] = []
        var skipNext = false
        var pastTerminator = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, arg == name, idx + 1 < args.count {
                values.append(args[idx + 1])
                skipNext = true
                continue
            }
            remaining.append(arg)
        }
        return (values, remaining)
    }

    func optionValue(_ args: [String], name: String) -> String? {
        for (index, arg) in args.enumerated() {
            if arg == "--" { return nil }
            if arg == name, index + 1 < args.count {
                return args[index + 1]
            }
            if arg.hasPrefix("\(name)=") {
                return String(arg.dropFirst(name.count + 1))
            }
        }
        return nil
    }

    func hasFlag(_ args: [String], name: String) -> Bool {
        args.contains(name)
    }
}
