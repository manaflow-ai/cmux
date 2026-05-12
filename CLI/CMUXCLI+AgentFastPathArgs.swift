import Foundation

extension CMUXCLI {
    func agentFastPathExtractFlags(
        _ flags: Set<String>,
        from args: [String],
        valueOptions: Set<String>
    ) -> (present: Set<String>, remaining: [String]) {
        var present = Set<String>()
        var remaining: [String] = []
        var pastTerminator = false
        var expectingOptionValue = false

        for arg in args {
            if expectingOptionValue {
                expectingOptionValue = false
                remaining.append(arg)
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, valueOptions.contains(arg) {
                expectingOptionValue = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, flags.contains(arg) {
                present.insert(arg)
                continue
            }
            remaining.append(arg)
        }

        return (present, remaining)
    }
}
