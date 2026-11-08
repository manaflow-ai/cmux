import Foundation
import Testing

struct ReplayHyperlinkProbe {
    static func hyperlinkedTextPainted(from data: Data) throws -> String {
        let text = try #require(String(data: data, encoding: .utf8))
        var probe = ReplayHyperlinkProbe()
        probe.consume(text)
        return probe.hyperlinkedText
    }

    private var hyperlinkActive = true
    private var hyperlinkedText = ""

    private mutating func consume(_ text: String) {
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "\u{1B}":
                index = consumeEscape(in: text, from: index)
            case "\u{0F}", "\r", "\n":
                index = text.index(after: index)
            default:
                if hyperlinkActive {
                    hyperlinkedText.append(text[index])
                }
                index = text.index(after: index)
            }
        }
    }

    private mutating func consumeEscape(in text: String, from escapeIndex: String.Index) -> String.Index {
        var index = text.index(after: escapeIndex)
        guard index < text.endIndex else { return index }
        if text[index] == "]" {
            return consumeOSC(in: text, from: text.index(after: index))
        }
        if text[index] == "[" {
            index = text.index(after: index)
            while index < text.endIndex, !isCSIFinalByte(text[index]) {
                index = text.index(after: index)
            }
            return index < text.endIndex ? text.index(after: index) : index
        }
        while index < text.endIndex, isESCIntermediateByte(text[index]) {
            index = text.index(after: index)
        }
        return index < text.endIndex ? text.index(after: index) : index
    }

    private mutating func consumeOSC(in text: String, from oscIndex: String.Index) -> String.Index {
        var index = oscIndex
        var payload = ""
        while index < text.endIndex {
            if text[index] == "\u{07}" {
                applyOSCPayload(payload)
                return text.index(after: index)
            }
            if text[index] == "\u{1B}" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\\" {
                    applyOSCPayload(payload)
                    return text.index(after: next)
                }
            }
            payload.append(text[index])
            index = text.index(after: index)
        }
        return index
    }

    private mutating func applyOSCPayload(_ payload: String) {
        guard payload.hasPrefix("8;") else { return }
        hyperlinkActive = payload != "8;;"
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
