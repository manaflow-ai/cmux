import Foundation
import CmuxNextCompat

nonisolated extension ClassicSessionImporter {
    struct DecodeBudget {
        var panels = 0
        var layoutNodes = 0
        var jsonNodes = 0
        var scrollbackBytes = 0
    }

    /// Applies structural and string ceilings before any topology or
    /// scrollback transformation allocates from the decoded snapshot.
    static func validate(_ workspace: [String: Any], budget: inout DecodeBudget) throws {
        let panels = (workspace["panels"] as? [[String: Any]]) ?? []
        guard panels.count <= maximumPanelsPerWorkspace else { throw ClassicSessionImportError.snapshotTooComplex }
        budget.panels += panels.count
        guard budget.panels <= maximumTotalPanels else { throw ClassicSessionImportError.snapshotTooComplex }

        guard let root = workspace["layout"] as? [String: Any] else { return }
        var layouts: [(value: [String: Any], depth: Int)] = [(root, 0)]
        while let next = layouts.popLast() {
            guard next.depth <= maximumLayoutDepth else { throw ClassicSessionImportError.snapshotTooComplex }
            budget.layoutNodes += 1
            guard budget.layoutNodes <= maximumLayoutNodes else { throw ClassicSessionImportError.snapshotTooComplex }
            if next.value["type"] as? String == "split" {
                let split = next.value["split"] as? [String: Any] ?? next.value
                if let first = split["first"] as? [String: Any] { layouts.append((first, next.depth + 1)) }
                if let second = split["second"] as? [String: Any] { layouts.append((second, next.depth + 1)) }
            } else {
                let pane = next.value["pane"] as? [String: Any] ?? next.value
                let ids = (pane["panelIds"] as? [String]) ?? (pane["panel_ids"] as? [String]) ?? []
                guard ids.count <= maximumPanelsPerWorkspace else { throw ClassicSessionImportError.snapshotTooComplex }
            }
        }
    }

    /// Bounds every decoded node and string, including metadata the importer
    /// does not currently consume.
    static func validateJSON(_ root: [String: Any], budget: inout DecodeBudget) throws {
        var pending: [(value: Any, key: String?)] = [(root, nil)]
        while let next = pending.popLast() {
            budget.jsonNodes += 1
            guard budget.jsonNodes <= maximumJSONNodes else { throw ClassicSessionImportError.snapshotTooComplex }
            switch next.value {
            case let text as String:
                let bytes = text.utf8.count
                if next.key == "scrollback" {
                    guard bytes <= maximumScrollbackBytes else { throw ClassicSessionImportError.snapshotTooComplex }
                    budget.scrollbackBytes += bytes
                    guard budget.scrollbackBytes <= maximumTotalScrollbackBytes else {
                        throw ClassicSessionImportError.snapshotTooComplex
                    }
                } else if bytes > maximumMetadataStringBytes {
                    throw ClassicSessionImportError.snapshotTooComplex
                }
            case let object as [String: Any]:
                guard budget.jsonNodes + pending.count + object.count <= maximumJSONNodes else {
                    throw ClassicSessionImportError.snapshotTooComplex
                }
                for (key, value) in object {
                    guard key.utf8.count <= maximumMetadataStringBytes else {
                        throw ClassicSessionImportError.snapshotTooComplex
                    }
                    pending.append((value: value, key: key))
                }
            case let array as [Any]:
                guard budget.jsonNodes + pending.count + array.count <= maximumJSONNodes else {
                    throw ClassicSessionImportError.snapshotTooComplex
                }
                for value in array { pending.append((value: value, key: next.key)) }
            default:
                break
            }
        }
    }

    /// Rejects large token graphs before `JSONSerialization` materializes
    /// Foundation collections. Classic writes UTF-8 JSON; NUL-bearing UTF-16
    /// input is deliberately not accepted by this import boundary.
    static func validateEncodedJSON(_ data: Data, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else {
            throw ClassicSessionImportError.snapshotTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumBytes
            )
        }
        try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var index = 0
            var depth = 0
            var tokens = 0
            var stringBytes = 0
            while index < bytes.count {
                let byte = bytes[index]
                switch byte {
                case 0:
                    throw ClassicSessionImportError.notASnapshot
                case 0x22:
                    tokens += 1
                    guard tokens <= maximumEncodedJSONTokens else {
                        throw ClassicSessionImportError.snapshotTooComplex
                    }
                    index += 1
                    var encodedBytes = 0
                    var closed = false
                    while index < bytes.count {
                        let character = bytes[index]
                        if character == 0x22 {
                            index += 1
                            closed = true
                            break
                        }
                        if character == 0x5C {
                            guard index + 1 < bytes.count else {
                                throw ClassicSessionImportError.notASnapshot
                            }
                            encodedBytes += 2
                            index += 2
                        } else {
                            guard character != 0 else { throw ClassicSessionImportError.notASnapshot }
                            encodedBytes += 1
                            index += 1
                        }
                        guard encodedBytes <= maximumEncodedStringBytes else {
                            throw ClassicSessionImportError.snapshotTooComplex
                        }
                    }
                    guard closed else { throw ClassicSessionImportError.notASnapshot }
                    guard encodedBytes <= maximumTotalEncodedStringBytes - stringBytes else {
                        throw ClassicSessionImportError.snapshotTooComplex
                    }
                    stringBytes += encodedBytes
                case 0x7B, 0x5B:
                    tokens += 1
                    depth += 1
                    guard tokens <= maximumEncodedJSONTokens, depth <= maximumJSONDepth else {
                        throw ClassicSessionImportError.snapshotTooComplex
                    }
                    index += 1
                case 0x7D, 0x5D:
                    if depth > 0 { depth -= 1 }
                    index += 1
                case 0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x3A:
                    index += 1
                default:
                    tokens += 1
                    guard tokens <= maximumEncodedJSONTokens else {
                        throw ClassicSessionImportError.snapshotTooComplex
                    }
                    var tokenBytes = 0
                    token: while index < bytes.count {
                        switch bytes[index] {
                        case 0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x3A, 0x7B, 0x7D, 0x5B, 0x5D:
                            break token
                        default:
                            break
                        }
                        guard bytes[index] != 0 else { throw ClassicSessionImportError.notASnapshot }
                        tokenBytes += 1
                        index += 1
                        guard tokenBytes <= maximumMetadataStringBytes else {
                            throw ClassicSessionImportError.snapshotTooComplex
                        }
                    }
                }
            }
        }
    }

    /// Reads one changing file through one descriptor and never retains more
    /// than the supplied limit plus the byte that proves it was exceeded.
    static func readData(at url: URL, maximumBytes: Int) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // concurrency-allow: callers hop to a detached utility task; the synchronous API stays fixture-testable.
        let handle = try FileHandle.blockingForReading(from: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard remaining > 0,
                  let chunk = try handle.blockingRead(upToCount: min(1024 * 1024, remaining)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else {
            throw ClassicSessionImportError.snapshotTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumBytes
            )
        }
        return data
    }
}
