public import Foundation

/// One named fixture: an acpmux `permission_request` record as a harness
/// sends it (`<name>.request.json`) and the question it must map to
/// (`<name>.json`). The UI Gallery renders `question`; tests check that
/// mapping `request` gives `question`; the web gallery reads the same files.
public struct AgentQuestionFixture: Sendable, Identifiable {
    public var name: String
    /// `{permissionId, session, request}`.
    public var request: AgentQuestionJSON
    public var question: AgentQuestion

    public var id: String { name }

    /// Every fixture name, sorted.
    public static var names: [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.map(\.lastPathComponent)
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".request.json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    /// The directory that holds the fixture files.
    public static var directory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures", isDirectory: true) // crash-allow: SwiftPM always bundles the Fixtures resource directory
    }

    public init(name: String) throws {
        let directory = Self.directory
        self.name = name
        request = try AgentQuestionJSON(data: Data(contentsOf: directory.appendingPathComponent("\(name).request.json")))
        question = try JSONDecoder().decode(AgentQuestion.self, from: Data(contentsOf: directory.appendingPathComponent("\(name).json")))
    }

    /// The question mapped from `request`, with the fixture's recorded state
    /// (answered and cancelled fixtures share a pending request).
    public func mapped() -> AgentQuestion? {
        guard let permission = request["permissionId"]?.string, let session = request["session"]?.string,
              var mapped = AgentQuestion(permissionRequest: request["request"] ?? .null, permissionId: permission, session: session)
        else { return nil }
        mapped.state = question.state
        return mapped
    }
}
