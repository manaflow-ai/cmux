import Foundation

/// A deterministic text CRDT used by the Phase 1 collaboration harness.
///
/// The document stores one immutable element per inserted character and marks
/// deletes with tombstones. Concurrent inserts after the same predecessor are
/// rendered by stable identifier order, so replicas converge even when
/// operations arrive out of order.
public struct CollaborationTextDocument: Codable, Equatable, Sendable {
    private var peerID: String
    private var nextCounter: Int
    private var elements: [CharacterID: TextElement]
    private var waitingByPredecessor: [CharacterID: [TextOperation]]

    /// Creates an empty text document for a peer.
    /// - Parameter peerID: The local peer identifier used for generated operations.
    public init(peerID: String) {
        self.peerID = peerID
        self.nextCounter = 0
        self.elements = [:]
        self.waitingByPredecessor = [:]
    }

    /// Creates a document initialized with plain text from the local peer.
    /// - Parameters:
    ///   - text: The initial document text.
    ///   - peerID: The local peer identifier used for generated operations.
    public init(text: String, peerID: String) {
        self.init(peerID: peerID)
        _ = replace(range: 0..<0, with: text)
    }

    /// The current visible text after applying all known operations.
    public var text: String {
        visibleElements().map(\.value).joined()
    }

    /// Replaces a visible UTF-8 character range with text and returns generated operations.
    /// - Parameters:
    ///   - range: The character-offset range to replace.
    ///   - replacement: The replacement text.
    /// - Returns: The operations that should be broadcast to other peers.
    @discardableResult
    public mutating func replace(range: Range<Int>, with replacement: String) -> [TextOperation] {
        let visible = visibleElements()
        let lowerBound = min(visible.count, max(0, range.lowerBound))
        let upperBound = min(visible.count, max(lowerBound, range.upperBound))
        let boundedRange = lowerBound..<upperBound
        var operations: [TextOperation] = []

        for element in visible[boundedRange] {
            let operation = TextOperation.delete(id: element.id)
            apply(operation)
            operations.append(operation)
        }

        var predecessor = boundedRange.lowerBound == 0 ? nil : visible[boundedRange.lowerBound - 1].id
        for character in replacement.map(String.init) {
            let id = CharacterID(peerID: peerID, counter: nextCounter)
            nextCounter += 1
            let operation = TextOperation.insert(id: id, after: predecessor, value: character)
            apply(operation)
            operations.append(operation)
            predecessor = id
        }

        return operations
    }

    /// Applies operations produced by another replica.
    /// - Parameter operations: Operations to merge into this document.
    public mutating func merge(_ operations: [TextOperation]) {
        for operation in operations {
            apply(operation)
        }
    }

    /// Exports all known operations as a full-state snapshot.
    /// - Returns: Operations sufficient to reconstruct this document state.
    public func snapshotOperations() -> [TextOperation] {
        var operations: [TextOperation] = []
        for element in elements.values.sorted(by: { $0.id < $1.id }) {
            operations.append(.insert(id: element.id, after: element.after, value: element.value))
        }
        for element in elements.values.sorted(by: { $0.id < $1.id }) where element.isDeleted {
            operations.append(.delete(id: element.id))
        }
        return operations
    }

    private mutating func apply(_ operation: TextOperation) {
        switch operation {
        case let .insert(id, after, value):
            guard elements[id] == nil else { return }
            if let after, elements[after] == nil {
                waitingByPredecessor[after, default: []].append(operation)
                return
            }
            elements[id] = TextElement(id: id, after: after, value: value, isDeleted: false)
            if nextCounter <= id.counter && id.peerID == peerID {
                nextCounter = id.counter + 1
            }
            drainWaiting(after: id)
        case let .delete(id):
            guard var element = elements[id] else {
                waitingByPredecessor[id, default: []].append(operation)
                return
            }
            element.isDeleted = true
            elements[id] = element
        }
    }

    private mutating func drainWaiting(after predecessor: CharacterID) {
        guard let waiting = waitingByPredecessor.removeValue(forKey: predecessor) else { return }
        for operation in waiting {
            apply(operation)
        }
    }

    private func visibleElements() -> [TextElement] {
        orderedElements().filter { !$0.isDeleted }
    }

    private func orderedElements() -> [TextElement] {
        let children = Dictionary(grouping: elements.values, by: \.after)
            .mapValues { $0.sorted { $0.id < $1.id } }
        var ordered: [TextElement] = []
        appendChildren(after: nil, children: children, into: &ordered)
        return ordered
    }

    private func appendChildren(
        after predecessor: CharacterID?,
        children: [CharacterID?: [TextElement]],
        into ordered: inout [TextElement]
    ) {
        for child in children[predecessor] ?? [] {
            ordered.append(child)
            appendChildren(after: child.id, children: children, into: &ordered)
        }
    }
}
