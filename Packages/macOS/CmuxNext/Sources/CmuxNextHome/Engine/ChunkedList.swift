/// A copy-on-write list in fixed chunks: appending or changing one element
/// copies one chunk, not the list, while an older value still shares the
/// storage. Prepends and evictions rebuild the chunks; the window that uses
/// it is bounded, so that stays O(window).
nonisolated struct ChunkedList<Element>: RandomAccessCollection {
    static var chunkSize: Int { 256 }
    private var chunks: [[Element]] = []
    private(set) var count = 0

    init() {}

    init(_ elements: some Collection<Element>) {
        let array = Array(elements)
        chunks = stride(from: 0, to: array.count, by: Self.chunkSize).map {
            Array(array[$0..<Swift.min(array.count, $0 + Self.chunkSize)])
        }
        count = array.count
    }

    var startIndex: Int { 0 }
    var endIndex: Int { count }

    subscript(index: Int) -> Element {
        get { chunks[index / Self.chunkSize][index % Self.chunkSize] }
        set { chunks[index / Self.chunkSize][index % Self.chunkSize] = newValue }
    }

    mutating func append(_ element: Element) {
        if let last = chunks.last, last.count < Self.chunkSize {
            chunks[chunks.count - 1].append(element)
        } else {
            chunks.append([element])
        }
        count += 1
    }

    mutating func append(contentsOf elements: some Sequence<Element>) {
        for element in elements { append(element) }
    }

    mutating func prepend(contentsOf elements: [Element]) {
        self = ChunkedList(elements + Array(self))
    }

    /// Drops `top` elements from the front and `bottom` from the back.
    mutating func remove(top: Int, bottom: Int) {
        let lower = Swift.min(top, count)
        let upper = Swift.max(lower, count - bottom)
        self = ChunkedList(Array(self)[lower..<upper])
    }
}

extension ChunkedList: Sendable where Element: Sendable {}
