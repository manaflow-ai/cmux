import Foundation

/// Finds suggested bang commands in original agent messages without screen-row reconstruction.
public enum BangCommandParser {
    /// Returns complete command text, preserving paths, quoting and real script newlines.
    public static func commands(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var commands: [String] = []
        var seen: Set<String> = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let inline = captures(#"\u0060(![ \t]+[^\u0060\r\n]+)\u0060"#, in: line)
            if !inline.isEmpty {
                for command in inline where seen.insert(command).inserted { commands.append(command) }
                continue
            }
            guard var command = captures(#"^\s*(?:[-*+]\s+)?(?:[^!\n]*:\s+)?(![ \t]+\S.*)$"#, in: line).first else {
                continue
            }
            while command.hasSuffix("\\"), index < lines.count {
                command += "\n" + lines[index]
                index += 1
            }
            let delimiters = captures(#"(?<!<)<<(?!<)-?[ \t]*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?"#, in: command)
            var complete = true
            for delimiter in delimiters {
                var closed = false
                while index < lines.count {
                    let bodyLine = lines[index]
                    index += 1
                    command += "\n" + bodyLine
                    if bodyLine.drop(while: { $0 == "\t" }) == delimiter {
                        closed = true
                        break
                    }
                }
                if !closed { complete = false; break }
            }
            if complete, seen.insert(command).inserted { commands.append(command) }
        }
        return commands
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap {
            $0.numberOfRanges > 1 ? source.substring(with: $0.range(at: 1)) : nil
        }
    }
}
