import Foundation

struct TerminalInputReportParser {
    private let scalars: [Unicode.Scalar]
    private let start: Int
    init(scalars: [Unicode.Scalar], start: Int) { self.scalars = scalars; self.start = start }
    func csiSequenceLength() -> Int? {
        guard start + 1 < scalars.count else { return nil }
        var cursor = start + 2
        while cursor < scalars.count {
            let value = scalars[cursor].value
            if value >= 0x40, value <= 0x7E { return isReport(bodyStart: start + 2, finalIndex: cursor) ? cursor - start + 1 : nil }
            guard value >= 0x20, value <= 0x3F else { return nil }
            cursor += 1
        }
        return nil
    }
    private func isReport(bodyStart: Int, finalIndex: Int) -> Bool {
        var parameterEnd = bodyStart
        while parameterEnd < finalIndex, (0x30...0x3F).contains(scalars[parameterEnd].value) { parameterEnd += 1 }
        guard scalars[parameterEnd..<finalIndex].allSatisfy({ (0x20...0x2F).contains($0.value) }) else { return false }
        let parameters = scalars[bodyStart..<parameterEnd].map(\.value)
        let intermediates = scalars[parameterEnd..<finalIndex].map(\.value)
        switch scalars[finalIndex].value {
        case 0x52: return intermediates.isEmpty && cursorReport(parameters)
        case 0x63: return intermediates.isEmpty && parameters.first.map { $0 == 0x3F || $0 == 0x3E } == true
        case 0x6E: return intermediates.isEmpty && (parameters.first == 0x3F || parameters == [0x30] || parameters == [0x33])
        case 0x75: return intermediates.isEmpty && parameters.first == 0x3F
        case 0x79: return intermediates == [0x24] && (parameters.first == 0x3F || ansiModeReport(parameters))
        case 0x74: return intermediates.isEmpty && cellSizeReport(parameters)
        default: return false
        }
    }
    private func cursorReport(_ p: [UInt32]) -> Bool {
        var fields = 0, digit = false
        for v in p { if (0x30...0x39).contains(v) { digit = true } else { guard v == 0x3B, digit else { return false }; fields += 1; digit = false } }
        guard digit else { return false }; return fields + 1 == 2
    }
    private func ansiModeReport(_ p: [UInt32]) -> Bool {
        guard let i = p.firstIndex(of: 0x3B), i > 0, i + 1 < p.count else { return false }
        return p[..<i].allSatisfy { (0x30...0x39).contains($0) } && p[(i + 1)...].count == 1 && (0x30...0x34).contains(p[i + 1])
    }

    private func cellSizeReport(_ p: [UInt32]) -> Bool {
        var fields: [[UInt32]] = []
        var field: [UInt32] = []
        for value in p {
            if (0x30...0x39).contains(value) {
                field.append(value)
            } else {
                guard value == 0x3B, !field.isEmpty else { return false }
                fields.append(field)
                field.removeAll(keepingCapacity: true)
            }
        }
        guard !field.isEmpty else { return false }
        fields.append(field)
        return fields.count == 3 && fields[0] == [0x36]
    }
}
