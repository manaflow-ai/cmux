#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its text input.
import CoreGraphics

// The text input's frames on the wire to the Chromium Host (chromium_host_wire.h: kIme,
// kTextInputWatch, kTextInputState). Ops go on the same stream as the page view's key frames,
// right after the frames written before them, as Chrome sends ImeSetComposition, ImeCommitText
// and the key events on one RenderWidgetHostNSViewHost pipe
// (content/common/render_widget_host_ns_view.mojom).

extension ChromiumHostFrame {
    /// The kIme frame of `op`.
    init(textInput op: ChromiumHostTextInputOp) {
        var v: [Int32] = [0, 0, 0, -1, -1, 0]
        var text = ""
        var clauses: [ChromiumHostCompositionClause] = []
        func replace(_ range: Range<Int>?) {
            guard let range else { return }
            v[3] = Int32(clamping: range.lowerBound)
            v[4] = Int32(clamping: range.upperBound)
        }
        switch op {
        case let .setComposition(composition, marked, selection, replacement):
            text = composition
            clauses = marked
            v[1] = Int32(clamping: selection.lowerBound)
            v[2] = Int32(clamping: selection.upperBound)
            replace(replacement)
            v[5] = Int32(clamping: marked.count)
        case let .commitText(committed, replacement):
            v[0] = 1
            text = committed
            replace(replacement)
        case .finishComposing:
            v[0] = 2
        case .cancelComposition:
            v[0] = 3
        case .keyCommands(let commands):
            v[0] = 4
            text = commands.joined(separator: "\n")
        case .editCommand(let command):
            v[0] = 5
            text = command
        }
        self.init(.ime, v: v, payload: ChromiumHostTextInputBytes.utf16LE(text) + ChromiumHostTextInputBytes.clauses(clauses))
    }
}

/// The byte layouts a text op's text and clauses take on both wires: a kIme frame's payload and the
/// remote shim's IME ops (``CEFShimTextInputOps``).
nonisolated enum ChromiumHostTextInputBytes {
    /// `text` as UTF-16LE.
    static func utf16LE(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf16.count * 2)
        for unit in text.utf16 { put(unit, into: &bytes) }
        return bytes
    }

    /// Per clause i32 start, i32 end, u32 color 0xAARRGGBB, u32 thick (0 or 1), little endian.
    static func clauses(_ clauses: [ChromiumHostCompositionClause]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(clauses.count * 16)
        for clause in clauses {
            put(Int32(clamping: clause.range.lowerBound), into: &bytes)
            put(Int32(clamping: clause.range.upperBound), into: &bytes)
            put(clause.color, into: &bytes)
            put(UInt32(clause.thick ? 1 : 0), into: &bytes)
        }
        return bytes
    }

    private static func put<T: FixedWidthInteger>(_ value: T, into bytes: inout [UInt8]) {
        bytes.appendLittleEndian(value)
    }
}

extension ChromiumHostTextInputState {
    /// The fixed part of a kTextInputState payload: caret x, y, width, height, text offset, rect count.
    private static let fixedBytes = 24

    /// The state a kTextInputState frame carries; nil for a frame that is not a well-formed one.
    init?(frame: ChromiumHostFrame) {
        guard frame.kind == .textInputState else { return nil }
        let bytes = frame.payload
        guard bytes.count >= Self.fixedBytes else { return nil }
        func int(_ offset: Int) -> Int32 {
            var value: UInt32 = 0
            for index in 0..<4 { value |= UInt32(bytes[offset + index]) << (8 * index) }
            return Int32(bitPattern: value)
        }
        func rect(_ offset: Int) -> CGRect {
            CGRect(x: CGFloat(int(offset)), y: CGFloat(int(offset + 4)), width: CGFloat(int(offset + 8)),
                   height: CGFloat(int(offset + 12)))
        }
        func range(_ start: Int32, _ end: Int32) -> Range<Int>? {
            start >= 0 && end >= start ? Int(start)..<Int(end) : nil
        }
        let textOffset = Int(int(16))
        let rectCount = Int(int(20))
        guard textOffset >= 0, rectCount >= 0, rectCount <= (bytes.count - Self.fixedBytes) / 16 else { return nil }
        let textStart = Self.fixedBytes + rectCount * 16
        guard (bytes.count - textStart) % 2 == 0 else { return nil }
        let units = stride(from: textStart, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        self.init(type: InputType(rawValue: frame.v[0]), flags: UInt32(bitPattern: frame.v[1]),
                  selection: range(frame.v[2], frame.v[3]), text: String(decoding: units, as: UTF16.self),
                  textOffset: textOffset, composition: range(frame.v[4], frame.v[5]),
                  compositionRects: (0..<rectCount).map { rect(Self.fixedBytes + 16 * $0) }, caretRect: rect(0))
    }
}
#endif
