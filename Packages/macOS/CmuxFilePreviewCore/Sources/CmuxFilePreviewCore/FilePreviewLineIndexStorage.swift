/// A compact implicit treap of line-start blocks.
///
/// Each node stores a bounded block of offsets rather than one node per line.
/// Suffix edits update a lazy delta on whole blocks, keeping both memory use
/// close to the original `[Int]` representation and edit work logarithmic in
/// the number of blocks.
struct FilePreviewLineIndexStorage: Sendable {
    private static let blockCapacity = 512

    private var nodes: [FilePreviewLineIndexStorageNode] = []
    private var freeNodes: [Int] = []
    private var root: Int?
    private var priorityState: UInt64 = 0x9E3779B97F4A7C15

    init() {}

    /// Adds line starts from a UTF-16 string without creating a second full
    /// document-sized offset array. Returns the string's UTF-16 length.
    mutating func appendLineStarts(from string: String) -> Int {
        var block = [0]
        block.reserveCapacity(Self.blockCapacity)
        var offset = 0
        for unit in string.utf16 {
            if unit == 10 {
                block.append(offset + 1)
                if block.count == Self.blockCapacity {
                    appendBlock(block)
                    block.removeAll(keepingCapacity: true)
                }
            }
            offset += 1
        }
        if !block.isEmpty {
            appendBlock(block)
        }
        return offset
    }

    var count: Int {
        root.map { nodes[$0].size } ?? 0
    }

    func values() -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(count)

        func visit(_ index: Int?, inheritedDelta: Int) {
            guard let index else { return }
            let node = nodes[index]
            let nodeDelta = inheritedDelta + node.lazyDelta
            visit(node.left, inheritedDelta: nodeDelta)
            result.append(contentsOf: node.offsets.map { $0 + nodeDelta })
            visit(node.right, inheritedDelta: nodeDelta)
        }

        visit(root, inheritedDelta: 0)
        return result
    }

    func value(at index: Int) -> Int? {
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
                return node.offsets[target - leftCount] + nodeDelta
            } else {
                target -= leftCount + node.offsets.count
                current = node.right
                inheritedDelta = nodeDelta
            }
        }
        return nil
    }

    func lowerBound(_ value: Int) -> Int {
        bound(value, upper: false)
    }

    func upperBound(_ value: Int) -> Int {
        bound(value, upper: true)
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

    mutating func insert(_ values: [Int], at index: Int) {
        guard !values.isEmpty else { return }
        let insertionIndex = min(max(index, 0), count)
        let (prefix, suffix) = split(root, byCount: insertionIndex)
        var inserted: Int?
        var start = 0
        while start < values.count {
            let end = min(values.count, start + Self.blockCapacity)
            let block = Array(values[start..<end])
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

    private func bound(_ value: Int, upper: Bool) -> Int {
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
            let firstValue = first + nodeDelta
            let lastValue = last + nodeDelta
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
                    let candidate = node.offsets[midpoint] + nodeDelta
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
            let (middle, right) = split(nodes[tree].right, byCount: count - leftCount - blockCount)
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
            nodes[tree].offsets[index] += delta
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
}
