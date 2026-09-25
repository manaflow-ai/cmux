public import Foundation

/// Interprets navigation, search, marks, and selection without any text mutation API.
///
/// Each preview owns one interpreter. Replace it when its document changes, and
/// call ``cancelPendingInput()`` when keyboard focus leaves the preview.
public struct ReadOnlyVimNavigation {
    private let buffer: ReadOnlyVimBuffer
    /// The cursor's UTF-16 offset, always on a composed-character boundary.
    public private(set) var cursor = 0
    /// Text produced by the most recent yank command, if any.
    public private(set) var yankedText: String?
    /// A viewport operation produced by the most recent key, if any.
    public private(set) var viewportAction: ReadOnlyVimViewportAction?
    /// The in-progress search prompt, including its direction prefix.
    public var searchPrompt: String? { searchInput.map { (searchBackwards ? "?" : "/") + $0 } }
    private var count = ""
    private var prefix = ""
    private var prefixCount = 1
    private var anchor: Int?
    private var linewise = false
    private var desiredColumn: Int?
    private var marks: [String: Int] = [:]
    private var jumps: [Int] = []
    private var jumpIndex = 0
    private var searchInput: String?
    private var searchPattern = ""
    private var searchBackwards = false
    private var lastFind: (String, Bool, Bool)?

    /// Creates navigation state over an immutable document snapshot.
    /// - Parameter text: The document to navigate.
    public init(text: String) { buffer = ReadOnlyVimBuffer(text) }

    /// The native text selection, or the insertion point outside visual mode.
    public var selection: NSRange {
        guard let anchor else { return NSRange(location: cursor, length: 0) }
        let start = min(anchor, cursor)
        let end = max(anchor, cursor)
        if linewise {
            let low = buffer.line(start).location
            return NSRange(location: low, length: NSMaxRange(buffer.line(end)) - low)
        }
        return NSRange(location: start, length: buffer.next(end) - start)
    }

    /// Synchronizes a native mouse selection or a viewport-driven cursor move.
    /// - Parameter offset: A UTF-16 position, clamped to the document.
    public mutating func move(to offset: Int) {
        cursor = buffer.clamp(offset)
        desiredColumn = nil
    }

    /// Adopts a mouse or native find selection and leaves Vim visual mode.
    /// - Parameter offset: The native selection's UTF-16 start.
    public mutating func adoptNativeCursor(_ offset: Int) {
        anchor = nil
        cancelPendingInput()
        move(to: offset)
    }

    /// Cancels an unfinished count, chord, or search when focus changes.
    public mutating func cancelPendingInput() {
        count = ""
        prefix = ""
        searchInput = nil
    }

    /// Processes one character or a canonical control key such as `ctrl+d`.
    ///
    /// Unknown and modifying commands are consumed without changing the document.
    /// - Parameter key: Case-sensitive character, `escape`, `enter`, `backspace`, or `ctrl+…`.
    public mutating func handle(_ key: String) {
        yankedText = nil
        viewportAction = nil
        if key == "escape" {
            cancelPendingInput()
            anchor = nil
            return
        }
        if var input = searchInput {
            if key == "enter" {
                searchInput = nil
                if !input.isEmpty { searchPattern = input }
                search(backwards: searchBackwards)
            } else if key == "backspace" {
                if input.isEmpty { searchInput = nil }
                else { input.removeLast(); searchInput = input }
            } else if key.count == 1 {
                searchInput = input + key
            }
            return
        }
        if !prefix.isEmpty {
            let pending = prefix
            prefix = ""
            finishPrefix(pending, key: key, repetitions: prefixCount)
            return
        }
        if key.utf8.count == 1, let digit = key.utf8.first, (48...57).contains(digit), key != "0" || !count.isEmpty {
            if count.count < 4 { count += key }
            return
        }
        let explicitCount = Int(count)
        let repetitions = max(1, explicitCount ?? 1)
        count = ""
        switch key {
        case "g", "z", "m", "'", "`", "f", "F", "t", "T":
            prefix = key; prefixCount = repetitions
        case "y":
            if let anchor { yank(selection); cursor = min(anchor, cursor); self.anchor = nil }
            else { prefix = key; prefixCount = repetitions }
        case "v", "V":
            if anchor != nil && linewise == (key == "V") { anchor = nil }
            else { anchor = cursor; linewise = key == "V" }
        case "/", "?": searchInput = ""; searchBackwards = key == "?"
        case "n", "N":
            search(backwards: key == "n" ? searchBackwards : !searchBackwards, count: repetitions)
        case "ctrl+o": jump(backwards: true, count: repetitions)
        case "ctrl+i": jump(backwards: false, count: repetitions)
        case "ctrl+d": viewportAction = .page(0.5 * Double(repetitions))
        case "ctrl+u": viewportAction = .page(-0.5 * Double(repetitions))
        case "ctrl+f": viewportAction = .page(Double(repetitions))
        case "ctrl+b": viewportAction = .page(-Double(repetitions))
        case "H": viewportAction = .visibleLine(0)
        case "M": viewportAction = .visibleLine(0.5)
        case "L": viewportAction = .visibleLine(1)
        case "G":
            recordJump()
            cursor = explicitCount.map { lineOffset($0) } ?? buffer.firstNonblank(buffer.clamp(buffer.length))
            desiredColumn = nil
        case ";", ",":
            if let (character, backwards, till) = lastFind {
                find(character, backwards: key == ";" ? backwards : !backwards, till: till, count: repetitions)
            }
        default: motion(key, count: repetitions)
        }
    }

    private mutating func motion(_ key: String, count: Int) {
        if key == "j" || key == "k" {
            let column = desiredColumn ?? buffer.column(cursor)
            cursor = buffer.vertical(cursor, delta: key == "j" ? count : -count, column: column)
            desiredColumn = column
            return
        }
        desiredColumn = nil
        for _ in 0..<count {
            switch key {
            case "h": cursor = max(buffer.line(cursor).location, buffer.previous(cursor))
            case "l": cursor = min(buffer.last(cursor), buffer.next(cursor))
            case "w", "W": cursor = buffer.word(cursor, direction: 1, ending: false, big: key == "W")
            case "b", "B": cursor = buffer.word(cursor, direction: -1, ending: false, big: key == "B")
            case "e", "E": cursor = buffer.word(cursor, direction: 1, ending: true, big: key == "E")
            case "0": cursor = buffer.line(cursor).location
            case "^": cursor = buffer.firstNonblank(cursor)
            case "$": cursor = buffer.last(cursor)
            case "{", "}":
                let delta = key == "}" ? 1 : -1
                var next = buffer.vertical(cursor, delta: delta, column: 0)
                while next != cursor {
                    let previous = cursor
                    cursor = next
                    if buffer.end(cursor) == buffer.line(cursor).location { break }
                    next = buffer.vertical(cursor, delta: delta, column: 0)
                    if next == previous { break }
                }
            default: return
            }
        }
    }

    private mutating func finishPrefix(_ prefix: String, key: String, repetitions: Int) {
        switch prefix {
        case "g":
            if key == "g" { recordJump(); cursor = lineOffset(repetitions); desiredColumn = nil }
        case "z":
            if key == "z" { viewportAction = .align(0.5) }
            if key == "t" { viewportAction = .align(0) }
            if key == "b" { viewportAction = .align(1) }
        case "m": if key.count == 1 { marks[key] = cursor }
        case "'", "`":
            if let target = marks[key] {
                recordJump(); cursor = prefix == "'" ? buffer.firstNonblank(target) : target
                desiredColumn = nil
            }
        case "f", "F", "t", "T":
            let backwards = prefix == "F" || prefix == "T"
            let till = prefix == "t" || prefix == "T"
            lastFind = (key, backwards, till)
            find(key, backwards: backwards, till: till, count: repetitions)
        case "y":
            let original = cursor
            if key == "y" {
                let end = buffer.vertical(cursor, delta: repetitions - 1, column: 0)
                yank(NSRange(location: buffer.line(cursor).location, length: NSMaxRange(buffer.line(end)) - buffer.line(cursor).location))
            } else if key == "j" || key == "k" {
                let target = buffer.vertical(cursor, delta: key == "j" ? repetitions : -repetitions, column: 0)
                let start = buffer.line(min(cursor, target)).location
                let end = NSMaxRange(buffer.line(max(cursor, target)))
                yank(NSRange(location: start, length: end - start))
            } else if key == "l" {
                var end = cursor
                let lineEnd = buffer.end(cursor)
                for _ in 0..<repetitions { end = min(lineEnd, buffer.next(end)) }
                if end > cursor { yank(NSRange(location: cursor, length: end - cursor)) }
            } else if ["h", "w", "W", "b", "B", "e", "E", "0", "^", "$", "{", "}"].contains(key) {
                motion(key, count: repetitions)
                let low = min(original, cursor)
                let high = max(original, cursor)
                let inclusive = ["e", "E", "$"].contains(key)
                yank(NSRange(location: low, length: (inclusive ? buffer.next(high) : high) - low))
                cursor = original
            }
        default: break
        }
    }

    private func lineOffset(_ number: Int) -> Int {
        buffer.firstNonblank(buffer.vertical(0, delta: max(0, number - 1), column: 0))
    }
    private mutating func yank(_ range: NSRange) {
        yankedText = buffer.text.substring(with: range)
    }
    private mutating func recordJump() {
        jumps = Array(jumps.prefix(jumpIndex))
        if jumps.last != cursor { jumps.append(cursor) }
        if jumps.count > 100 { jumps.removeFirst() }
        jumpIndex = jumps.count
    }
    private mutating func jump(backwards: Bool, count: Int) {
        guard !jumps.isEmpty else { return }
        if jumpIndex == jumps.count { jumps.append(cursor) }
        jumpIndex = min(jumps.count - 1, max(0, jumpIndex + (backwards ? -count : count)))
        cursor = jumps[jumpIndex]
        desiredColumn = nil
    }
    private mutating func find(_ key: String, backwards: Bool, till: Bool, count: Int) {
        guard key.count == 1 else { return }
        var position = cursor
        let lineStart = buffer.line(cursor).location
        let lineEnd = buffer.end(cursor)
        for _ in 0..<count {
            var candidate = backwards ? buffer.previous(position) : buffer.next(position)
            while candidate >= lineStart && candidate < lineEnd && candidate != position {
                if buffer.character(candidate) == key { break }
                let next = backwards ? buffer.previous(candidate) : buffer.next(candidate)
                if next == candidate { return }
                candidate = next
            }
            guard candidate != position, buffer.character(candidate) == key else { return }
            position = candidate
        }
        cursor = till ? (backwards ? buffer.next(position) : buffer.previous(position)) : position
        desiredColumn = nil
    }
    private mutating func search(backwards: Bool, count: Int = 1) {
        guard !searchPattern.isEmpty,
              let expression = try? NSRegularExpression(pattern: searchPattern, options: .anchorsMatchLines) else { return }
        let source = buffer.text as String
        let whole = NSRange(location: 0, length: buffer.length)
        // Enumerate once per command, even for the maximum four-digit count.
        var offsets: [Int] = []
        let document = buffer
        expression.enumerateMatches(in: source, range: whole) { result, _, _ in
            if let offset = result?.range.location { offsets.append(document.clamp(offset)) }
        }
        guard !offsets.isEmpty else { return }
        var index: Int
        if backwards {
            index = offsets.lastIndex(where: { $0 < cursor }) ?? offsets.count - 1
        } else {
            index = offsets.firstIndex(where: { $0 > cursor }) ?? 0
        }
        for _ in 0..<count {
            recordJump()
            cursor = offsets[index]
            index = (index + (backwards ? offsets.count - 1 : 1)) % offsets.count
        }
        desiredColumn = nil
    }
}
