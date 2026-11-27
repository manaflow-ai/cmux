import CmuxNextSettings
@testable import CmuxNextPages
import Foundation

/// A page provider that answers the Settings page's first reads and records every op and stream.
@MainActor
final class RecordingPageProvider: PageProvider {
    var ops: [String] = []
    var streams: [String] = []
    var onRecord: (() -> Void)?

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        ops.append(op)
        onRecord?()
        switch op {
        case "cmux.settings.list":
            return [["key": "test.row", "value": .null, "default": .null, "customized": false, "managed": .null]]
        case "cmux.settings.snapshot":
            return ["revision": 1, "schema_hash": "", "effective": .object([:]), "managed": .object([:]), "diagnostics": .array([])]
        default: return .object([:])
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        streams.append(stream)
        onRecord?()
        return PageSubscription {}
    }

    var readAndListened: Bool {
        ops.contains("cmux.settings.list") && ops.contains("cmux.settings.snapshot")
            && streams.contains("cmux.settings.changed")
    }
}
