public import Foundation

/// The layout-motion contract's judge for native views: the same rules as the pages' judge
/// (webviews/src/layout/motionJudge.ts), read from the same file (schemas/layout-motion/contract.json) and held
/// to the same cases (schemas/layout-motion/vectors.json, LayoutMotionJudgeVectorsTests). Leo, 2026-11-18: "I was
/// thinking we'd be able to calculate each beforehand everything that would move and just go ok well nothing
/// else usually should and the things that move we only expect at certain times etc ... Fundamentally".
///
/// A box that drew in one place for `restFrames` frames and then moves or resizes by more than `slackPx`, with
/// no declaration open in that frame (or the one before) whose event its surface allows, is an undeclared move.
public nonisolated struct LayoutMotionContract: Sendable {
    public let restFrames: Int
    public let slackPx: Double
    /// Surface id to the events a box of it may move on.
    public let moves: [String: Set<String>]
    public let events: Set<String>

    public static func repoRoot(from file: String = #filePath) throws -> URL {
        var root = URL(fileURLWithPath: file)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("schemas/layout-motion/contract.json").path) {
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { throw CocoaError(.fileNoSuchFile) }
            root = parent
        }
        return root
    }

    public static func load() throws -> LayoutMotionContract {
        let data = try Data(contentsOf: try repoRoot().appendingPathComponent("schemas/layout-motion/contract.json"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [String: Any],
              let surfaces = json["surfaces"] as? [[String: Any]]
        else { throw CocoaError(.fileReadCorruptFile) }
        var moves: [String: Set<String>] = [:]
        for surface in surfaces {
            guard let id = surface["id"] as? String, let list = surface["moves"] as? [String] else { continue }
            moves[id] = Set(list)
        }
        return LayoutMotionContract(
            restFrames: json["restFrames"] as? Int ?? 2,
            slackPx: json["slackPx"] as? Double ?? 0.5,
            moves: moves,
            events: Set(events.keys)
        )
    }
}

public nonisolated struct LayoutMotionSample: Sendable, Equatable {
    public var label: String
    public var surface: String
    public var box: CGRect
    public var targeted = false
    public var after = false
    public var before = false
    public var animating = false

    public init(label: String, surface: String, box: CGRect, targeted: Bool = false, after: Bool = false,
                before: Bool = false, animating: Bool = false) {
        self.label = label
        self.surface = surface
        self.box = box
        self.targeted = targeted
        self.after = after
        self.before = before
        self.animating = animating
    }
}

public nonisolated struct LayoutMotionDeclaration: Sendable, Equatable {
    public enum Scope: String, Sendable { case all, targets }
    public var key: Int
    public var event: String
    public var scope: Scope
    public var once = false

    public init(key: Int, event: String, scope: Scope, once: Bool = false) {
        self.key = key
        self.event = event
        self.scope = scope
        self.once = once
    }
}

public nonisolated struct LayoutMotionFrame: Sendable {
    public var samples: [String: LayoutMotionSample]
    public var declared: [LayoutMotionDeclaration]

    public init(samples: [String: LayoutMotionSample], declared: [LayoutMotionDeclaration] = []) {
        self.samples = samples
        self.declared = declared
    }
}

public nonisolated struct UndeclaredLayoutMove: Sendable, Equatable, CustomStringConvertible {
    public var label: String
    public var surface: String
    public var frame: Int
    public var dx, dy, dw, dh: Double
    public var during: [String]

    public var description: String {
        "\(label) (\(surface)) at frame \(frame): [\(dx) \(dy) \(dw) \(dh)] during \(during.isEmpty ? "nothing" : during.joined(separator: ","))"
    }
}

public nonisolated struct LayoutMotionVerdict: Sendable {
    /// Boxes that made at least one undeclared move.
    public var undeclared: Int
    public var moves: [UndeclaredLayoutMove]
}

public nonisolated func judgeLayoutMotion(_ frames: [LayoutMotionFrame], contract: LayoutMotionContract) -> LayoutMotionVerdict {
    var still: [String: Int] = [:]
    var usedOnce: Set<String> = []
    var flagged: Set<String> = []
    var moves: [UndeclaredLayoutMove] = []
    func covers(_ declaration: LayoutMotionDeclaration, _ sample: LayoutMotionSample, dx: Double, dy: Double) -> Bool {
        guard contract.moves[sample.surface]?.contains(declaration.event) == true else { return false }
        if declaration.scope == .all || sample.targeted { return true }
        let straight = abs(dx) <= contract.slackPx
        if sample.after, dy > 0, straight { return true }
        return sample.before && dy < 0 && straight
    }
    for index in frames.indices.dropFirst() {
        let previous = frames[index - 1]
        let current = frames[index]
        let open = current.declared + previous.declared.filter { was in !current.declared.contains { $0.key == was.key } }
        for (id, now) in current.samples.sorted(by: { $0.key < $1.key }) {
            guard let was = previous.samples[id] else {
                still[id] = nil
                continue
            }
            if now.animating || was.animating {
                still[id] = 0
                continue
            }
            let dx = now.box.minX - was.box.minX
            let dy = now.box.minY - was.box.minY
            let dw = now.box.width - was.box.width
            let dh = now.box.height - was.box.height
            guard max(abs(dx), abs(dy), abs(dw), abs(dh)) > contract.slackPx else {
                still[id, default: 0] += 1
                continue
            }
            guard still[id, default: 0] >= contract.restFrames else {
                still[id] = 0
                continue
            }
            let declared = open.contains { declaration in
                guard covers(declaration, now, dx: dx, dy: dy) else { return false }
                guard declaration.once else { return true }
                return usedOnce.insert("\(declaration.key):\(id)").inserted
            }
            if declared || flagged.contains(id) { continue }
            flagged.insert(id)
            let round = { (value: Double) in (value * 10).rounded() / 10 }
            moves.append(UndeclaredLayoutMove(label: now.label, surface: now.surface, frame: index, dx: round(dx), dy: round(dy),
                                              dw: round(dw), dh: round(dh), during: Array(Set(open.map(\.event))).sorted()))
        }
    }
    return LayoutMotionVerdict(undeclared: flagged.count, moves: moves)
}
