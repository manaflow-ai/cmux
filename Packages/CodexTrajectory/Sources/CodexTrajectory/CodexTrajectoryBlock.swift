import Foundation

public enum CodexTrajectoryBlockKind: String, Codable, CaseIterable, Sendable {
    case userText
    case assistantText
    case commandOutput
    case toolCall
    case fileChange
    case approvalRequest
    case status
    case warning
    case stderr
    case systemEvent
}

public struct CodexTrajectoryBlock: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var kind: CodexTrajectoryBlockKind
    public var title: String
    public var text: String
    public var isStreaming: Bool
    public var createdAt: Date

    public init(
        id: String,
        kind: CodexTrajectoryBlockKind,
        title: String = "",
        text: String,
        isStreaming: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.isStreaming = isStreaming
        self.createdAt = createdAt
    }

    public var displayText: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return text
        }
        guard !text.isEmpty else {
            return trimmedTitle
        }
        return "\(trimmedTitle)\n\(text)"
    }
}

public struct CodexTrajectoryStore: Sendable {
    public private(set) var blocks: [CodexTrajectoryBlock]
    private var indexByID: [String: Int]

    public init(blocks: [CodexTrajectoryBlock] = []) {
        self.blocks = []
        self.indexByID = [:]
        for block in blocks {
            append(block)
        }
    }

    public var isEmpty: Bool {
        blocks.isEmpty
    }

    public var count: Int {
        blocks.count
    }

    public subscript(id id: String) -> CodexTrajectoryBlock? {
        guard let index = indexByID[id] else { return nil }
        return blocks[index]
    }

    public mutating func append(_ block: CodexTrajectoryBlock) {
        if let index = indexByID[block.id] {
            blocks[index] = block
            return
        }
        indexByID[block.id] = blocks.count
        blocks.append(block)
    }

    public mutating func appendText(_ text: String, toBlock id: String) {
        guard let index = indexByID[id], !text.isEmpty else { return }
        blocks[index].text += text
    }

    public mutating func replaceText(_ text: String, inBlock id: String) {
        guard let index = indexByID[id] else { return }
        blocks[index].text = text
    }

    public mutating func setStreaming(_ isStreaming: Bool, forBlock id: String) {
        guard let index = indexByID[id] else { return }
        blocks[index].isStreaming = isStreaming
    }

    public mutating func removeAll(keepingCapacity keepCapacity: Bool = false) {
        blocks.removeAll(keepingCapacity: keepCapacity)
        indexByID.removeAll(keepingCapacity: keepCapacity)
    }
}
