import Foundation

/// Declarative per-agent/per-alert sound matrix.
///
/// The JSON representation is an object keyed by stable agent ids, with alert
/// types beneath each agent. Missing cells resolve to the global sound.
nonisolated public struct NotificationSoundOverrides: Codable, Equatable, Sendable {
    private var storage: [String: [NotificationSoundAlertType: NotificationSoundOverride]]

    /// Creates a sparse matrix, dropping invalid keys, empty rows, and rows
    /// beyond the persisted cardinality bound.
    ///
    /// - Parameter storage: Cells grouped by stable agent identifier.
    public init(
        storage: [String: [NotificationSoundAlertType: NotificationSoundOverride]] = [:]
    ) {
        let validRows = storage
            .filter {
                NotificationSoundOverrideContext.isValidAgentID($0.key)
                    && !$0.value.isEmpty
            }
            .sorted { $0.key < $1.key }
            .prefix(Self.maximumAgentCount)
        self.storage = validRows.reduce(into: [:]) { result, row in
            result[row.key] = row.value
        }
    }

    /// An empty matrix, equivalent to leaving every cell unset.
    public static let empty = NotificationSoundOverrides()

    /// Maximum UTF-8 size accepted for a persisted matrix.
    public static let maximumJSONBytes = 256 * 1024

    /// Maximum number of agent rows accepted in a persisted matrix.
    public static let maximumAgentCount = 256

    /// Maximum number of alert cells accepted beneath one agent row.
    public static let maximumCellsPerAgent = 3

    /// Whether the matrix contains no configured cells.
    public var isEmpty: Bool { storage.isEmpty }

    /// Stable agent identifiers with at least one configured cell.
    public var agentIDs: [String] { storage.keys.sorted() }

    /// Looks up one configured cell without applying global fallback.
    ///
    /// - Parameters:
    ///   - agentID: The stable agent identifier.
    ///   - alertType: The semantic alert class.
    /// - Returns: The configured cell, or `nil` when the cell is unset.
    public func override(
        forAgentID agentID: String,
        alertType: NotificationSoundAlertType
    ) -> NotificationSoundOverride? {
        storage[agentID]?[alertType]
    }

    /// Inserts or removes one sparse matrix cell.
    ///
    /// - Parameters:
    ///   - value: The override, or `nil` to restore global fallback.
    ///   - agentID: The stable agent identifier.
    ///   - alertType: The semantic alert class.
    public mutating func set(
        _ value: NotificationSoundOverride?,
        forAgentID agentID: String,
        alertType: NotificationSoundAlertType
    ) {
        let normalized = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NotificationSoundOverrideContext.isValidAgentID(normalized) else { return }
        if let value {
            storage[normalized, default: [:]][alertType] = value
        } else {
            storage[normalized]?[alertType] = nil
            if storage[normalized]?.isEmpty == true {
                storage[normalized] = nil
            }
        }
    }

    /// Decodes a matrix from its canonical JSON string representation.
    ///
    /// - Parameter jsonString: A JSON object keyed by agent and alert type.
    public init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? Self(jsonData: data) else { return nil }
        self = decoded
    }

    /// Decodes a matrix from JSON data.
    ///
    /// - Parameter jsonData: UTF-8 JSON data for the sparse matrix.
    /// - Throws: ``DecodingError`` when a key or cell is invalid.
    public init(jsonData: Data) throws {
        guard jsonData.count <= Self.maximumJSONBytes else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Notification sound override JSON exceeds the maximum size"
            ))
        }
        self = try JSONDecoder().decode(Self.self, from: jsonData)
    }

    /// Serializes a settings-file object only when its matrix shape and encoded
    /// size stay within the runtime bounds.
    ///
    /// The shape check runs before ``JSONSerialization/data(withJSONObject:)``
    /// so a hostile object with hundreds of oversized cell values is rejected
    /// without first allocating its complete nested byte representation. The
    /// final encoded-size check accounts for JSON escaping overhead.
    ///
    /// - Parameter object: JSON-compatible object from the declarative settings
    ///   parser, expected to be keyed by agent id and alert type.
    /// - Returns: Canonical JSON data, or `nil` when the object is malformed or
    ///   exceeds the matrix bounds.
    public static func boundedJSONData(fromJSONObject object: Any) -> Data? {
        guard hasBoundedJSONObjectShape(object),
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              ),
              data.count <= maximumJSONBytes else {
            return nil
        }
        return data
    }

    /// Canonical, deterministic JSON suitable for config persistence.
    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              data.count <= Self.maximumJSONBytes,
              let value = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return value
    }

    private struct DynamicCodingKey: CodingKey, Hashable {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    /// Decodes dynamic agent and alert keys while rejecting unknown values.
    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard root.allKeys.count <= Self.maximumAgentCount else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Too many notification sound override agents"
            ))
        }
        var decoded: [String: [NotificationSoundAlertType: NotificationSoundOverride]] = [:]
        for agentKey in root.allKeys {
            let agentID = agentKey.stringValue
            guard NotificationSoundOverrideContext.isValidAgentID(agentID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: agentKey,
                    in: root,
                    debugDescription: "Invalid notification sound override agent id"
                )
            }
            let agentContainer = try root.nestedContainer(
                keyedBy: DynamicCodingKey.self,
                forKey: agentKey
            )
            guard agentContainer.allKeys.count <= Self.maximumCellsPerAgent else {
                throw DecodingError.dataCorruptedError(
                    forKey: agentKey,
                    in: root,
                    debugDescription: "Too many notification sound override cells"
                )
            }
            var cells: [NotificationSoundAlertType: NotificationSoundOverride] = [:]
            for alertKey in agentContainer.allKeys {
                guard let alertType = NotificationSoundAlertType(rawValue: alertKey.stringValue) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: alertKey,
                        in: agentContainer,
                        debugDescription: "Unknown notification sound alert type"
                    )
                }
                cells[alertType] = try agentContainer.decode(
                    NotificationSoundOverride.self,
                    forKey: alertKey
                )
            }
            if !cells.isEmpty {
                decoded[agentID] = cells
            }
        }
        storage = decoded
    }

    private static func hasBoundedJSONObjectShape(_ object: Any) -> Bool {
        guard let agents = object as? [String: Any],
              agents.count <= maximumAgentCount else {
            return false
        }

        var estimatedBytes = 2 // Root braces.
        for (agentID, rawCells) in agents {
            guard NotificationSoundOverrideContext.isValidAgentID(agentID),
                  let cells = rawCells as? [String: Any],
                  cells.count <= maximumCellsPerAgent,
                  addEstimatedBytes(
                      &estimatedBytes,
                      agentID.utf8.count + 4
                  ) else {
                return false
            }
            for (alertType, rawCell) in cells {
                guard NotificationSoundAlertType(rawValue: alertType) != nil,
                      let cell = rawCell as? [String: Any],
                      cell.count <= 2,
                      addEstimatedBytes(
                          &estimatedBytes,
                          alertType.utf8.count + 4
                      ) else {
                    return false
                }
                for (key, rawValue) in cell {
                    guard key == "sound" || key == "customSoundFilePath",
                          let value = rawValue as? String,
                          addEstimatedBytes(
                              &estimatedBytes,
                              key.utf8.count + value.utf8.count + 6
                          ) else {
                        return false
                    }
                }
            }
        }
        return estimatedBytes <= maximumJSONBytes
    }

    private static func addEstimatedBytes(
        _ total: inout Int,
        _ additional: Int
    ) -> Bool {
        let (updated, overflow) = total.addingReportingOverflow(additional)
        guard !overflow, updated <= maximumJSONBytes else { return false }
        total = updated
        return true
    }

    /// Encodes dynamic agent and alert keys in deterministic sorted order.
    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: DynamicCodingKey.self)
        for agentID in storage.keys.sorted() {
            guard let agentKey = DynamicCodingKey(stringValue: agentID),
                  let cells = storage[agentID] else { continue }
            var agentContainer = root.nestedContainer(
                keyedBy: DynamicCodingKey.self,
                forKey: agentKey
            )
            for alertType in cells.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let alertKey = DynamicCodingKey(stringValue: alertType.rawValue),
                      let value = cells[alertType] else { continue }
                try agentContainer.encode(value, forKey: alertKey)
            }
        }
    }
}
