/// A compact implicit treap of line-break blocks.
///
/// Each node stores a bounded block of packed break offsets rather than one
/// node per line. Suffix edits update a lazy delta on whole blocks, keeping
/// edits logarithmic in the number of blocks. The low three bits retain the
/// separator kind, so CRLF pairing remains exact without a second document
/// copy or a parallel metadata array.
struct FilePreviewLineIndexStorage: Sendable {
    private static let blockCapacity = 512
    private static let kindMask = 0b111

    private var nodes: [FilePreviewLineIndexStorageNode] = []
    private var freeNodes: [Int] = []
    private var root: Int?
    private var priorityState: UInt64 = 0x9E3779B97F4A7C15

    init() {}

    /// Adds line breaks from a UTF-16 string without creating a second
    /// document-sized offset array. Returns the string's UTF-16 length.
    mutating func appendLineStarts(from string: String) -> Int {
        var block: [Int] = []
        block.reserveCapacity(Self.blockCapacity)
        var position = 0
        var pendingCarriageReturn = false
        for unit in string.utf16 {
            if pendingCarriageReturn {
                if unit == 0x0A {
                    block.append(Self.pack(FilePreviewLineBreakUnit(
                        offset: position - 1,
                        kind: .carriageReturnLineFeed
                    )))
                    if block.count == Self.blockCapacity {
                        appendBlock(block)
                        block = []
                        block.reserveCapacity(Self.blockCapacity)
                    }
                    pendingCarriageReturn = false
                    position += 1
                    continue
                }
                block.append(Self.pack(FilePreviewLineBreakUnit(
                    offset: position - 1,
                    kind: .carriageReturn
                )))
                if block.count == Self.blockCapacity {
                    appendBlock(block)
                    block = []
                    block.reserveCapacity(Self.blockCapacity)
                }
                pendingCarriageReturn = false
            }

            switch unit {
            case 0x0D:
                pendingCarriageReturn = true
            case 0x0A:
                block.append(Self.pack(FilePreviewLineBreakUnit(
                    offset: position,
                    kind: .lineFeed
                )))
                if block.count == Self.blockCapacity {
                    appendBlock(block)
                    block = []
                    block.reserveCapacity(Self.blockCapacity)
                }
            case 0x2028:
                block.append(Self.pack(FilePreviewLineBreakUnit(
                    offset: position,
                    kind: .lineSeparator
                )))
                if block.count == Self.blockCapacity {
                    appendBlock(block)
                    block = []
                    block.reserveCapacity(Self.blockCapacity)
                }
            case 0x2029:
                block.append(Self.pack(FilePreviewLineBreakUnit(
                    offset: position,
                    kind: .paragraphSeparator
                )))
                if block.count == Self.blockCapacity {
                    appendBlock(block)
                    block = []
                    block.reserveCapacity(Self.blockCapacity)
                }
            default:
                break
            }
            position += 1
        }
        if pendingCarriageReturn {
            block.append(Self.pack(FilePreviewLineBreakUnit(
                offset: position - 1,
                kind: .carriageReturn
            )))
            if block.count == Self.blockCapacity {
                appendBlock(block)
                block = []
                block.reserveCapacity(Self.blockCapacity)
            }
        }
        if !block.isEmpty {
            appendBlock(block)
        }
        return position
    }

    /// Returns the number of logical lines in the document.
    var lineCount: Int {
        count + 1
    }

    /// Number of stored logical line-break events.
    var count: Int {
        root.map { nodes[$0].size } ?? 0
    }

    /// Materializes line starts for diagnostics and tests.
    func values() -> [Int] {
        var result: [Int] = [0]
        result.reserveCapacity(lineCount)

        func visit(_ index: Int?, inheritedDelta: Int) {
            guard let index else { return }
            let node = nodes[index]
            let nodeDelta = inheritedDelta + node.lazyDelta
            visit(node.left, inheritedDelta: nodeDelta)
            for packed in node.offsets {
                let lineBreak = Self.unpack(packed, delta: nodeDelta)
                result.append(lineBreak.offset + lineBreak.kind.length)
            }
            visit(node.right, inheritedDelta: nodeDelta)
        }

        visit(root, inheritedDelta: 0)
        return result
    }

    /// Returns one logical line break by zero-based event index.
    func lineBreak(at index: Int) -> FilePreviewLineBreakUnit? {
        guard index >= 0, index < count else { return nil }
        var current = root
        var target = index
        var inheritedDelta = 0
        while let nodeIndex = current {
            let node = nodes[nodeIndex]
            let nodeDelta = inheritedDelta + node.lazyDelta
            let leftCount = size(of: node.left)
            if target < leftCount {
                current = node.left
                inheritedDelta = nodeDelta
            } else if target < leftCount + node.offsets.count {
                return Self.unpack(
                    node.offsets[target - leftCount],
                    delta: nodeDelta
                )
            } else {
                target -= leftCount + node.offsets.count
                current = node.right
                inheritedDelta = nodeDelta
            }
        }
        return nil
    }

    /// Returns a logical line start by zero-based line index.
    func lineStart(at index: Int) -> Int? {
        guard index >= 0, index < lineCount else { return nil }
        guard index > 0, let lineBreak = lineBreak(at: index - 1) else { return 0 }
        return lineBreak.offset + lineBreak.kind.length
    }

    /// Number of line starts at or before `value`.
    func lineStartsThrough(_ value: Int) -> Int {
        guard value >= 0 else { return 0 }
        return 1 + boundEnd(value, upper: true)
    }

    /// Index of the first break whose start is at least `value`.
    func lowerBoundStart(_ value: Int) -> Int {
        boundStart(value, upper: false)
    }

    /// Index of the first break whose end is greater than `value`.
    func firstEnd(after value: Int) -> Int {
        boundEnd(value, upper: true)
    }

    mutating func add(_ delta: Int, toSuffixFrom start: Int) {
        guard delta != 0, start < count else { return }
        let (prefix, suffix) = split(root, byCount: max(0, start))
        apply(delta, to: suffix)
        root = merge(prefix, suffix)
    }

    mutating func remove(range: Range<Int>) {
        guard !range.isEmpty,
              range.lowerBound >= 0,
              range.upperBound <= count else { return }
        let (prefix, rest) = split(root, byCount: range.lowerBound)
        let (removed, suffix) = split(rest, byCount: range.count)
        recycle(removed)
        root = merge(prefix, suffix)
    }

    mutating func insert(_ lineBreaks: [FilePreviewLineBreakUnit], at index: Int) {
        guard !lineBreaks.isEmpty else { return }
        let insertionIndex = min(max(index, 0), count)
        let (prefix, suffix) = split(root, byCount: insertionIndex)
        var inserted: Int?
        var start = 0
        while start < lineBreaks.count {
            let end = min(lineBreaks.count, start + Self.blockCapacity)
            let block = lineBreaks[start..<end].map(Self.pack)
            let node = allocate(offsets: block)
            inserted = merge(inserted, node)
            start = end
        }
        root = merge(merge(prefix, inserted), suffix)
    }

    private mutating func appendBlock(_ offsets: [Int]) {
        guard !offsets.isEmpty else { return }
        root = merge(root, allocate(offsets: offsets))
    }

    private func boundStart(_ value: Int, upper: Bool) -> Int {
        var current = root
        var result = 0
        var inheritedDelta = 0
        while let nodeIndex = current {
            let node = nodes[nodeIndex]
            let nodeDelta = inheritedDelta + node.lazyDelta
            let leftCount = size(of: node.left)
            guard let first = node.offsets.first, let last = node.offsets.last else {
                current = node.right
                inheritedDelta = nodeDelta
                result += leftCount
                continue
            }
            let firstValue = Self.unpackOffset(first) + nodeDelta
            let lastValue = Self.unpackOffset(last) + nodeDelta
            let goesLeft = upper ? value < firstValue : value <= firstValue
            let goesRight = upper ? value >= lastValue : value > lastValue
            if goesLeft {
                current = node.left
                inheritedDelta = nodeDelta
            } else if goesRight {
                result += leftCount + node.offsets.count
                current = node.right
                inheritedDelta = nodeDelta
            } else {
                result += leftCount
                var low = 0
                var high = node.offsets.count
                while low < high {
                    let midpoint = (low + high) / 2
                    let candidate = Self.unpackOffset(node.offsets[midpoint]) + nodeDelta
                    if upper ? candidate <= value : candidate < value {
                        low = midpoint + 1
                    } else {
                        high = midpoint
                    }
                }
                return result + low
            }
        }
        return result
    }

    private func boundEnd(_ value: Int, upper: Bool) -> Int {
        var current = root
        var result = 0
        var inheritedDelta = 0
        while let nodeIndex = current {
            let node = nodes[nodeIndex]
            let nodeDelta = inheritedDelta + node.lazyDelta
            let leftCount = size(of: node.left)
            guard let first = node.offsets.first, let last = node.offsets.last else {
                current = node.right
                inheritedDelta = nodeDelta
                result += leftCount
                continue
            }
            let firstValue = Self.unpackEnd(first) + nodeDelta
            let lastValue = Self.unpackEnd(last) + nodeDelta
            let goesLeft = upper ? value < firstValue : value <= firstValue
            let goesRight = upper ? value >= lastValue : value > lastValue
            if goesLeft {
                current = node.left
                inheritedDelta = nodeDelta
            } else if goesRight {
                result += leftCount + node.offsets.count
                current = node.right
                inheritedDelta = nodeDelta
            } else {
                result += leftCount
                var low = 0
                var high = node.offsets.count
                while low < high {
                    let midpoint = (low + high) / 2
                    let candidate = Self.unpackEnd(node.offsets[midpoint]) + nodeDelta
                    if upper ? candidate <= value : candidate < value {
                        low = midpoint + 1
                    } else {
                        high = midpoint
                    }
                }
                return result + low
            }
        }
        return result
    }

    private mutating func split(_ tree: Int?, byCount count: Int) -> (Int?, Int?) {
        guard let tree else { return (nil, nil) }
        push(tree)
        let leftCount = size(of: nodes[tree].left)
        let blockCount = nodes[tree].offsets.count
        if count < leftCount {
            let (left, middle) = split(nodes[tree].left, byCount: count)
            nodes[tree].left = middle
            pull(tree)
            return (left, tree)
        }
        if count > leftCount + blockCount {
            let (middle, right) = split(
                nodes[tree].right,
                byCount: count - leftCount - blockCount
            )
            nodes[tree].right = middle
            pull(tree)
            return (tree, right)
        }
        if count == leftCount {
            let left = nodes[tree].left
            nodes[tree].left = nil
            pull(tree)
            return (left, tree)
        }
        if count == leftCount + blockCount {
            let right = nodes[tree].right
            nodes[tree].right = nil
            pull(tree)
            return (tree, right)
        }

        let within = count - leftCount
        let leftChild = nodes[tree].left
        let rightChild = nodes[tree].right
        let leftOffsets = Array(nodes[tree].offsets[..<within])
        let rightOffsets = Array(nodes[tree].offsets[within...])
        releaseNode(tree)
        let leftTree = merge(leftChild, allocate(offsets: leftOffsets))
        let rightTree = merge(allocate(offsets: rightOffsets), rightChild)
        return (leftTree, rightTree)
    }

    private mutating func merge(_ left: Int?, _ right: Int?) -> Int? {
        guard let left else { return right }
        guard let right else { return left }
        if nodes[left].priority >= nodes[right].priority {
            push(left)
            nodes[left].right = merge(nodes[left].right, right)
            pull(left)
            return left
        }
        push(right)
        nodes[right].left = merge(left, nodes[right].left)
        pull(right)
        return right
    }

    private mutating func apply(_ delta: Int, to tree: Int?) {
        guard let tree else { return }
        nodes[tree].lazyDelta += delta
    }

    private mutating func push(_ tree: Int) {
        let delta = nodes[tree].lazyDelta
        guard delta != 0 else { return }
        let left = nodes[tree].left
        let right = nodes[tree].right
        apply(delta, to: left)
        apply(delta, to: right)
        for index in nodes[tree].offsets.indices {
            let lineBreak = Self.unpack(nodes[tree].offsets[index])
            nodes[tree].offsets[index] = Self.pack(
                FilePreviewLineBreakUnit(
                    offset: lineBreak.offset + delta,
                    kind: lineBreak.kind
                )
            )
        }
        nodes[tree].lazyDelta = 0
    }

    private mutating func pull(_ tree: Int) {
        nodes[tree].size = nodes[tree].offsets.count
            + size(of: nodes[tree].left)
            + size(of: nodes[tree].right)
    }

    private mutating func recycle(_ tree: Int?) {
        guard let tree else { return }
        let left = nodes[tree].left
        let right = nodes[tree].right
        recycle(left)
        recycle(right)
        releaseNode(tree)
    }

    private mutating func releaseNode(_ tree: Int) {
        nodes[tree].offsets.removeAll(keepingCapacity: false)
        nodes[tree].left = nil
        nodes[tree].right = nil
        nodes[tree].size = 0
        nodes[tree].lazyDelta = 0
        freeNodes.append(tree)
    }

    private func size(of tree: Int?) -> Int {
        tree.map { nodes[$0].size } ?? 0
    }

    private mutating func allocate(offsets: [Int]) -> Int {
        let node = FilePreviewLineIndexStorageNode(offsets: offsets, priority: nextPriority())
        if let recycled = freeNodes.popLast() {
            nodes[recycled] = node
            return recycled
        }
        nodes.append(node)
        return nodes.count - 1
    }

    private mutating func nextPriority() -> UInt64 {
        priorityState &+= 0x9E3779B97F4A7C15
        var value = priorityState
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    @inline(__always)
    private static func pack(_ lineBreak: FilePreviewLineBreakUnit) -> Int {
        // File Preview caps text at 16 MiB, well below this packed offset's
        // representable limit. Keeping the invariant here avoids widening
        // every dense line entry with a separate kind field. Callers only pass
        // validated, non-negative UTF-16 offsets.
        (lineBreak.offset << 3) | lineBreak.kind.rawValue
    }

    private static func unpack(_ packed: Int, delta: Int = 0) -> FilePreviewLineBreakUnit {
        let kind = FilePreviewLineBreakKind(rawValue: packed & kindMask) ?? .lineFeed
        return FilePreviewLineBreakUnit(
            offset: (packed >> 3) + delta,
            kind: kind
        )
    }

    private static func unpackOffset(_ packed: Int) -> Int {
        packed >> 3
    }

    private static func unpackEnd(_ packed: Int) -> Int {
        unpackOffset(packed) + (FilePreviewLineBreakKind(rawValue: packed & kindMask)?.length ?? 1)
    }
}
