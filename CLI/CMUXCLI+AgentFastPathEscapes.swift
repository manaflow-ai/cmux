extension CMUXCLI {
    func agentFastPathUnescapeSendText(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var isEscaping = false

        for character in text {
            if isEscaping {
                switch character {
                case "n":
                    output.append("\n")
                case "r":
                    output.append("\r")
                case "t":
                    output.append("\t")
                case "\\":
                    output.append("\\")
                default:
                    output.append("\\")
                    output.append(character)
                }
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                output.append(character)
            }
        }

        if isEscaping {
            output.append("\\")
        }
        return output
    }
}
