import Foundation
@testable import CmuxAcpmux

/// Loads acpmux event fixtures captured from a real daemon.
struct FixtureLoader {
    let bundle = Bundle.module

    func url(_ name: String) throws -> URL {
        guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    /// `_acpmux/attach` result captured from the fake agent.
    func fakeAttach() throws -> AcpmuxAttachResult {
        try JSONDecoder().decode(AcpmuxAttachResult.self, from: Data(contentsOf: url("fake-attach.json")))
    }

    /// Raw on-disk records from a real codex session.
    func codexSessionRecords() throws -> [AcpmuxEventRecord] {
        let text = try String(contentsOf: url("codex-session-events.ndjson"), encoding: .utf8)
        return try text.split(separator: "\n").map {
            try JSONDecoder().decode(AcpmuxEventRecord.self, from: Data($0.utf8))
        }
    }

    /// Live notifications captured while the fake-agent session ran.
    func fakeLiveNotifications() throws -> [JSONRPCNotification] {
        let text = try String(contentsOf: url("fake-live-notifications.ndjson"), encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            return JSONRPCNotification(method: value["method"]?.stringValue ?? "", params: value["params"] ?? .null)
        }
    }
}
