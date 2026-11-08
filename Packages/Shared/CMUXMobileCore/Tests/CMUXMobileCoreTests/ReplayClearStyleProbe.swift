import Foundation
import Testing

struct ReplayClearStyleProbe {
    static func clearBackgrounds(from data: Data) throws -> [String] {
        let text = try #require(String(data: data, encoding: .utf8))
        var probe = ReplayClearStyleProbe()
        probe.consume(text)
        return probe.clearBackgrounds
    }

    private var activeBackground = "stale"
    private var clearBackgrounds: [String] = []

    private mutating func consume(_ text: String) {
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "\u{1B}" else {
                index = text.index(after: index)
                continue
            }
            index = consumeEscape(in: text, from: index)
        }
    }

    private mutating func consumeEscape(in text: String, from escapeIndex: String.Index) -> String.Index {
        var index = text.index(after: escapeIndex)
        guard index < text.endIndex else { return index }
        if text[index] == "]" {
            return consumeOSC(in: text, from: text.index(after: index))
        }
        guard text[index] == "[" else {
            while index < text.endIndex, isESCIntermediateByte(text[index]) {
                index = text.index(after: index)
            }
            return index < text.endIndex ? text.index(after: index) : index
        }
        index = text.index(after: index)
        let parametersStart = index
        while index < text.endIndex, !isCSIFinalByte(text[index]) {
            index = text.index(after: index)
        }
        guard index < text.endIndex else { return index }
        consumeCSI(parameters: String(text[parametersStart..<index]), final: text[index])
        return text.index(after: index)
    }

    private mutating func consumeOSC(in text: String, from oscIndex: String.Index) -> String.Index {
        var index = oscIndex
        while index < text.endIndex {
            if text[index] == "\u{07}" {
                return text.index(after: index)
            }
            if text[index] == "\u{1B}" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\\" {
                    return text.index(after: next)
                }
            }
            index = text.index(after: index)
        }
        return index
    }

    private mutating func consumeCSI(parameters: String, final: Character) {
        switch final {
        case "J" where parameters.contains("2"):
            clearBackgrounds.append(activeBackground)
        case "m":
            applySGR(parameters)
        default:
            break
        }
    }

    private mutating func applySGR(_ parameters: String) {
        let values = parameters
            .split(separator: ";")
            .map { Int($0) ?? 0 }
        if values.isEmpty {
            activeBackground = "default"
            return
        }
        var index = 0
        while index < values.count {
            switch values[index] {
            case 0:
                activeBackground = "default"
                index += 1
            case 48 where index + 4 < values.count && values[index + 1] == 2:
                activeBackground = String(
                    format: "#%02x%02x%02x",
                    values[index + 2],
                    values[index + 3],
                    values[index + 4]
                )
                index += 5
            default:
                index += 1
            }
        }
    }

    private func isCSIFinalByte(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else {
            return false
        }
        return (0x40...0x7E).contains(scalar.value)
    }

    private func isESCIntermediateByte(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else {
            return false
        }
        return (0x20...0x2F).contains(scalar.value)
    }
}
