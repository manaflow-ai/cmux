import Foundation

/// Binary wire form of a render-grid frame.
///
/// Render grids are the hottest payload between the Mac and a phone: every
/// captured terminal change becomes one frame. JSON cost a Codable encode on
/// the Mac, a JSON parse plus Codable decode on the phone, and repeated key
/// names on the wire. This form is a flat byte string that both sides walk
/// once: integers are LEB128 varints, colors that are canonical `#RRGGBB`
/// strings travel as three bytes, style flags pack into one varint, and text
/// is length-prefixed UTF-8. Theme and timing metadata ride along as embedded
/// JSON because they appear on a handful of frames per session.
///
/// A frame on the event wire starts with ``binaryFrameKind``, a byte no JSON
/// envelope can start with, so both kinds share one length-prefixed lane.
/// ``binaryFormatVersion`` changes whenever the layout does; there is no
/// negotiation, because a Mac and phone are built from the same source.
extension MobileTerminalRenderGridFrame {
    /// Event topic render-grid frames are delivered under.
    public static let eventTopic = "terminal.render_grid"
    public static let binaryFrameKind: UInt8 = 0x01
    public static let binaryFormatVersion: UInt8 = 2

    public enum BinaryDecodingError: Error, Equatable, Sendable {
        case truncated
        case wrongKind(UInt8)
        case unsupportedVersion(UInt8)
        case invalidValue(String)
    }

    /// Whether `payload` is a binary render-grid frame rather than a JSON event.
    public static func isBinaryFrame(_ payload: Data) -> Bool {
        payload.first == binaryFrameKind
    }

    public func binaryEncoded() throws -> Data {
        var writer = RenderGridBinaryWriter()
        writer.byte(Self.binaryFrameKind)
        writer.byte(Self.binaryFormatVersion)
        var flags: UInt64 = 0
        if full { flags |= 1 << 0 }
        if anchor == .screen { flags |= 1 << 1 }
        if activeScreen == .alternate { flags |= 1 << 2 }
        writer.varint(flags)
        writer.string(surfaceID)
        writer.varint(stateSeq)
        writer.optionalVarint(appliedInputSequence)
        writer.string(renderEpoch)
        writer.varint(renderRevision)
        writer.varint(UInt64(columns))
        writer.varint(UInt64(rows))
        writer.cursor(cursor)
        writer.varint(UInt64(clearedRows.count))
        for row in clearedRows { writer.varint(UInt64(row)) }
        writer.varint(UInt64(styles.count))
        for style in styles { writer.style(style) }
        writer.spans(rowSpans)
        writer.varint(UInt64(modes.count))
        for mode in modes {
            writer.varint(UInt64(mode.code))
            writer.byte((mode.ansi ? 1 : 0) | (mode.on ? 2 : 0))
        }
        writer.color(terminalForeground)
        writer.color(terminalBackground)
        writer.color(terminalCursorColor)
        try writer.json(terminalTheme)
        try writer.json(terminalConfigTheme)
        writer.optionalVarint(terminalThemeRevision)
        writer.varint(UInt64(scrollbackRows))
        writer.spans(scrollbackSpans)
        writer.varint(UInt64(scrolledRows))
        writer.optionalVarint(historyRows)
        writer.optionalVarint(rowSpaceRevision)
        writer.optionalVarint(deltaBaseHistoryRows)
        writer.optionalVarint(deltaBaseRenderRevision)
        try writer.json(hostTiming)
        return writer.data
    }

    /// Decodes and validates a frame produced by ``binaryEncoded()``.
    public static func decodeBinary(_ payload: Data) throws -> MobileTerminalRenderGridFrame {
        var reader = RenderGridBinaryReader(payload)
        let kind = try reader.byte()
        guard kind == binaryFrameKind else { throw BinaryDecodingError.wrongKind(kind) }
        let version = try reader.byte()
        guard version == binaryFormatVersion else { throw BinaryDecodingError.unsupportedVersion(version) }
        let flags = try reader.varint()
        let surfaceID = try reader.string()
        let stateSeq = try reader.varint()
        let appliedInputSequence = try reader.optionalVarint()
        let renderEpoch = try reader.string()
        let renderRevision = try reader.varint()
        let columns = try reader.int()
        let rows = try reader.int()
        let cursor = try reader.cursor()
        let clearedRows = try (0..<reader.count()).map { _ in try reader.int() }
        let styles = try (0..<reader.count()).map { _ in try reader.style() }
        let rowSpans = try reader.spans()
        let modes = try (0..<reader.count()).map { _ in
            let code = try reader.int()
            let bits = try reader.byte()
            return ModeSetting(code: code, ansi: bits & 1 != 0, on: bits & 2 != 0)
        }
        let terminalForeground = try reader.color()
        let terminalBackground = try reader.color()
        let terminalCursorColor = try reader.color()
        let terminalTheme = try reader.json(TerminalTheme.self)
        let terminalConfigTheme = try reader.json(TerminalTheme.self)
        let terminalThemeRevision = try reader.optionalVarint()
        let scrollbackRows = try reader.int()
        let scrollbackSpans = try reader.spans()
        let scrolledRows = try reader.int()
        let historyRows = try reader.optionalVarint()
        let rowSpaceRevision = try reader.optionalVarint()
        let deltaBaseHistoryRows = try reader.optionalVarint()
        let deltaBaseRenderRevision = try reader.optionalVarint()
        let hostTiming = try reader.json(MobileTerminalHostTiming.self)
        guard reader.isAtEnd else { throw BinaryDecodingError.invalidValue("trailing bytes") }
        var frame = try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            appliedInputSequence: appliedInputSequence,
            renderEpoch: renderEpoch,
            renderRevision: renderRevision,
            columns: columns,
            rows: rows,
            cursor: cursor,
            full: flags & (1 << 0) != 0,
            clearedRows: clearedRows,
            styles: styles,
            rowSpans: rowSpans,
            activeScreen: flags & (1 << 2) != 0 ? .alternate : .primary,
            modes: modes,
            terminalForeground: terminalForeground,
            terminalBackground: terminalBackground,
            terminalCursorColor: terminalCursorColor,
            terminalTheme: terminalTheme,
            terminalConfigTheme: terminalConfigTheme,
            terminalThemeRevision: terminalThemeRevision,
            scrollbackRows: scrollbackRows,
            scrollbackSpans: scrollbackSpans,
            anchor: flags & (1 << 1) != 0 ? .screen : .viewport,
            scrolledRows: scrolledRows,
            historyRows: historyRows,
            rowSpaceRevision: rowSpaceRevision,
            deltaBaseHistoryRows: deltaBaseHistoryRows,
            deltaBaseRenderRevision: deltaBaseRenderRevision
        )
        frame.hostTiming = hostTiming
        return frame
    }
}

// MARK: - Byte-level helpers

private enum ColorTag: UInt8 {
    case none = 0
    case upperHex = 1
    case lowerHex = 2
    case text = 3
}

private struct RenderGridBinaryWriter {
    var data = Data()

    init() { data.reserveCapacity(512) }

    mutating func byte(_ value: UInt8) { data.append(value) }

    mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    /// 0 means nil; otherwise value + 1. Callers never store UInt64.max.
    mutating func optionalVarint(_ value: UInt64?) {
        varint(value.map { $0 &+ 1 } ?? 0)
    }

    mutating func string(_ value: String) {
        let utf8 = value.utf8
        varint(UInt64(utf8.count))
        data.append(contentsOf: utf8)
    }

    mutating func color(_ value: String?) {
        guard let value else { return byte(ColorTag.none.rawValue) }
        if let (rgb, isUpper) = Self.hexRGB(value) {
            byte(isUpper ? ColorTag.upperHex.rawValue : ColorTag.lowerHex.rawValue)
            data.append(contentsOf: rgb)
        } else {
            byte(ColorTag.text.rawValue)
            string(value)
        }
    }

    mutating func cursor(_ cursor: MobileTerminalRenderGridFrame.Cursor?) {
        guard let cursor else { return byte(0) }
        let shape: UInt8 = switch cursor.style {
        case .block: 0
        case .bar: 1
        case .underline: 2
        case .blockHollow: 3
        }
        byte(1 | (cursor.visible ? 2 : 0) | (cursor.blinking ? 4 : 0) | (shape << 3))
        varint(UInt64(cursor.row))
        varint(UInt64(cursor.column))
    }

    mutating func style(_ style: MobileTerminalRenderGridFrame.Style) {
        varint(UInt64(style.id))
        var flags: UInt64 = 0
        let bits = [
            style.bold, style.faint, style.italic, style.underline, style.blink,
            style.inverse, style.invisible, style.strikethrough, style.overline,
        ]
        for (index, isSet) in bits.enumerated() where isSet { flags |= 1 << UInt64(index) }
        varint(flags)
        color(style.foreground)
        color(style.background)
        byte(Self.sourceByte(style.foregroundSource) | (Self.sourceByte(style.backgroundSource) << 2))
        optionalVarint(style.foregroundPaletteIndex.map { UInt64(truncatingIfNeeded: $0) })
        optionalVarint(style.backgroundPaletteIndex.map { UInt64(truncatingIfNeeded: $0) })
    }

    mutating func spans(_ spans: [MobileTerminalRenderGridFrame.RowSpan]) {
        varint(UInt64(spans.count))
        for span in spans {
            varint(UInt64(span.row))
            varint(UInt64(span.column))
            varint(UInt64(span.styleID))
            optionalVarint(span.cellWidth.map { UInt64(truncatingIfNeeded: $0) })
            string(span.text)
        }
    }

    mutating func json<Value: Encodable>(_ value: Value?) throws {
        guard let value else { return varint(0) }
        let encoded = try JSONEncoder().encode(value)
        varint(UInt64(encoded.count) + 1)
        data.append(encoded)
    }

    private static func sourceByte(_ source: MobileTerminalRenderGridFrame.Style.ColorSource?) -> UInt8 {
        switch source {
        case nil: 0
        case .defaultColor: 1
        case .palette: 2
        case .rgb: 3
        }
    }

    /// `#RRGGBB` in one consistent letter case, so the string round-trips.
    private static func hexRGB(_ value: String) -> ([UInt8], Bool)? {
        let utf8 = Array(value.utf8)
        guard utf8.count == 7, utf8[0] == UInt8(ascii: "#") else { return nil }
        var hasUpper = false
        var hasLower = false
        var nibbles: [UInt8] = []
        nibbles.reserveCapacity(6)
        for character in utf8[1...] {
            switch character {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                nibbles.append(character - UInt8(ascii: "0"))
            case UInt8(ascii: "A")...UInt8(ascii: "F"):
                hasUpper = true
                nibbles.append(character - UInt8(ascii: "A") + 10)
            case UInt8(ascii: "a")...UInt8(ascii: "f"):
                hasLower = true
                nibbles.append(character - UInt8(ascii: "a") + 10)
            default:
                return nil
            }
        }
        guard !(hasUpper && hasLower) else { return nil }
        let rgb = [nibbles[0] << 4 | nibbles[1], nibbles[2] << 4 | nibbles[3], nibbles[4] << 4 | nibbles[5]]
        return (rgb, !hasLower)
    }
}

private struct RenderGridBinaryReader {
    typealias Failure = MobileTerminalRenderGridFrame.BinaryDecodingError

    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = Array(data) }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw Failure.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let next = try byte()
            guard shift < 64 else { throw Failure.invalidValue("varint overflow") }
            result |= UInt64(next & 0x7F) << shift
            if next & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func optionalVarint() throws -> UInt64? {
        let raw = try varint()
        return raw == 0 ? nil : raw - 1
    }

    mutating func int() throws -> Int {
        let value = try varint()
        guard value <= UInt64(Int32.max) else { throw Failure.invalidValue("integer out of range") }
        return Int(value)
    }

    /// An element count, bounded by the bytes left so a corrupt count cannot
    /// make the caller allocate before failing.
    mutating func count() throws -> Int {
        let value = try int()
        guard value <= bytes.count - offset else { throw Failure.truncated }
        return value
    }

    mutating func rawBytes(_ length: Int) throws -> ArraySlice<UInt8> {
        guard length <= bytes.count - offset else { throw Failure.truncated }
        defer { offset += length }
        return bytes[offset..<(offset + length)]
    }

    mutating func string() throws -> String {
        let length = try count()
        guard let value = String(bytes: try rawBytes(length), encoding: .utf8) else {
            throw Failure.invalidValue("invalid UTF-8")
        }
        return value
    }

    mutating func color() throws -> String? {
        let tagByte = try byte()
        guard let tag = ColorTag(rawValue: tagByte) else { throw Failure.invalidValue("color tag \(tagByte)") }
        switch tag {
        case .none:
            return nil
        case .upperHex, .lowerHex:
            let rgb = try rawBytes(3)
            let format = tag == .upperHex ? "#%02X%02X%02X" : "#%02x%02x%02x"
            return String(format: format, rgb[rgb.startIndex], rgb[rgb.startIndex + 1], rgb[rgb.startIndex + 2])
        case .text:
            return try string()
        }
    }

    mutating func cursor() throws -> MobileTerminalRenderGridFrame.Cursor? {
        let bits = try byte()
        guard bits & 1 != 0 else { return nil }
        let style: MobileTerminalRenderGridFrame.Cursor.Style
        switch bits >> 3 {
        case 0: style = .block
        case 1: style = .bar
        case 2: style = .underline
        case 3: style = .blockHollow
        default: throw Failure.invalidValue("cursor shape")
        }
        let row = try int()
        let column = try int()
        return .init(row: row, column: column, visible: bits & 2 != 0, style: style, blinking: bits & 4 != 0)
    }

    mutating func style() throws -> MobileTerminalRenderGridFrame.Style {
        let id = try int()
        let flags = try varint()
        let foreground = try color()
        let background = try color()
        let sources = try byte()
        let foregroundPaletteIndex = try optionalVarint().map { Int(truncatingIfNeeded: $0) }
        let backgroundPaletteIndex = try optionalVarint().map { Int(truncatingIfNeeded: $0) }
        func flag(_ index: UInt64) -> Bool { flags & (1 << index) != 0 }
        return .init(
            id: id,
            foreground: foreground,
            background: background,
            foregroundSource: try Self.source(sources & 0b11),
            foregroundPaletteIndex: foregroundPaletteIndex,
            backgroundSource: try Self.source((sources >> 2) & 0b11),
            backgroundPaletteIndex: backgroundPaletteIndex,
            bold: flag(0),
            faint: flag(1),
            italic: flag(2),
            underline: flag(3),
            blink: flag(4),
            inverse: flag(5),
            invisible: flag(6),
            strikethrough: flag(7),
            overline: flag(8)
        )
    }

    mutating func spans() throws -> [MobileTerminalRenderGridFrame.RowSpan] {
        try (0..<count()).map { _ in
            let row = try int()
            let column = try int()
            let styleID = try int()
            let cellWidth = try optionalVarint().map { Int(truncatingIfNeeded: $0) }
            let text = try string()
            return .init(row: row, column: column, styleID: styleID, text: text, cellWidth: cellWidth)
        }
    }

    mutating func json<Value: Decodable>(_: Value.Type) throws -> Value? {
        let raw = try varint()
        guard raw > 0 else { return nil }
        let length = Int(clamping: raw - 1)
        return try JSONDecoder().decode(Value.self, from: Data(try rawBytes(length)))
    }

    private static func source(_ bits: UInt8) throws -> MobileTerminalRenderGridFrame.Style.ColorSource? {
        switch bits {
        case 0: nil
        case 1: .defaultColor
        case 2: .palette
        case 3: .rgb
        default: throw Failure.invalidValue("color source")
        }
    }
}
