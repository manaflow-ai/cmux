import Foundation

/// Why a priority matrix JSON document was rejected.
public enum SessionPriorityMatrixError: Error, Equatable {
    /// A value that must be an object is not; `path` is dot-joined (`""` for the root).
    case notAnObject(path: String)
    /// An object has a key the matrix does not define; `path` is dot-joined.
    case unknownKey(path: String)
    /// An `effort` is not a `ClaudeEffortLevel` raw value.
    case invalidEffort(String)
    /// A `model` does not match `SessionPriorityMatrix.modelPattern`.
    case invalidModel(String)
}

/// Maps a (tier, difficulty) pair to the effort and model a session should run with.
public struct SessionPriorityMatrix: Equatable, Sendable {
    /// Allowed model strings: a short alias or id with no shell-significant characters.
    public static let modelPattern = "^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"

    /// The matrix cmux ships with: effort only, no model overrides.
    public static let shippedDefault = SessionPriorityMatrix(cells: [
        .urgent: [.easy: .init(effort: .medium), .normal: .init(effort: .high), .hard: .init(effort: .xhigh)],
        .slow: [.easy: .init(effort: .low), .normal: .init(effort: .medium), .hard: .init(effort: .medium)],
    ])

    private let cells: [SessionPriorityTier: [ClaudeSessionDifficulty: SessionPriorityTarget]]

    private init(cells: [SessionPriorityTier: [ClaudeSessionDifficulty: SessionPriorityTarget]]) {
        self.cells = cells
    }

    /// Decodes and validates a matrix document over `shippedDefault`. A cell you write replaces that
    /// whole cell (`{}` means not adjusted); cells you leave out keep the default. Unknown keys are rejected.
    public init(json: Data) throws {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw SessionPriorityMatrixError.notAnObject(path: "")
        }
        var parsed = Self.shippedDefault.cells
        for (tierKey, tierValue) in root {
            guard let tier = SessionPriorityTier(rawValue: tierKey) else {
                throw SessionPriorityMatrixError.unknownKey(path: tierKey)
            }
            guard let difficulties = tierValue as? [String: Any] else {
                throw SessionPriorityMatrixError.notAnObject(path: tierKey)
            }
            for (difficultyKey, cellValue) in difficulties {
                let path = "\(tierKey).\(difficultyKey)"
                guard let difficulty = ClaudeSessionDifficulty(rawValue: difficultyKey) else {
                    throw SessionPriorityMatrixError.unknownKey(path: path)
                }
                guard let cell = cellValue as? [String: Any] else {
                    throw SessionPriorityMatrixError.notAnObject(path: path)
                }
                let target = try Self.target(fromCell: cell, path: path)
                parsed[tier, default: [:]][difficulty] = target
            }
        }
        self.cells = parsed
    }

    private static func target(fromCell cell: [String: Any], path: String) throws -> SessionPriorityTarget {
        var target = SessionPriorityTarget()
        for (key, value) in cell {
            switch key {
            case "effort":
                guard let raw = value as? String, let effort = ClaudeEffortLevel(rawValue: raw) else {
                    throw SessionPriorityMatrixError.invalidEffort((value as? String) ?? String(describing: value))
                }
                target.effort = effort
            case "model":
                guard let model = value as? String, isValidModel(model) else {
                    throw SessionPriorityMatrixError.invalidModel((value as? String) ?? String(describing: value))
                }
                target.model = model
            default:
                throw SessionPriorityMatrixError.unknownKey(path: "\(path).\(key)")
            }
        }
        return target
    }

    private static func isValidModel(_ model: String) -> Bool {
        model.range(of: modelPattern, options: .regularExpression) != nil
    }

    /// Parses a stored setting value; empty or invalid input yields `shippedDefault`.
    public static func fromStoredString(_ s: String) -> SessionPriorityMatrix {
        (try? SessionPriorityMatrix(json: Data(s.utf8))) ?? .shippedDefault
    }

    /// Sorted-key, whitespace-free JSON containing all six cells; an empty cell is `{}`.
    public func canonicalJSONString() -> String {
        var root: [String: Any] = [:]
        for (tier, row) in cells {
            var tierObject: [String: Any] = [:]
            for (difficulty, target) in row {
                var cell: [String: Any] = [:]
                if let effort = target.effort { cell["effort"] = effort.rawValue }
                if let model = target.model { cell["model"] = model }
                tierObject[difficulty.rawValue] = cell
            }
            root[tier.rawValue] = tierObject
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    /// The target for a cell; empty when the cell is `{}`.
    public func target(tier: SessionPriorityTier, difficulty: ClaudeSessionDifficulty) -> SessionPriorityTarget {
        cells[tier]?[difficulty] ?? SessionPriorityTarget()
    }
}
