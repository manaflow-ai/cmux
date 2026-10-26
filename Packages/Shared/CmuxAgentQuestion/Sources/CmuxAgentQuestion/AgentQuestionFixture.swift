import CmuxThreading
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

    /// Every fixture name, sorted. Lists the bundle's folder: a checked blocking call.
    public static var names: [String] {
        let directory = Self.directory
        let urls = blockingCall(.fileIO) {
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        }
        return urls.map(\.lastPathComponent)
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".request.json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    /// The directory that holds the fixture files.
    public static var directory: URL {
        // SwiftPM bundles the Fixtures resource directory; the bundle root stands in rather than a trap.
        (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// Reads the fixture's two files from the bundle: a checked blocking call.
    ///
    /// - Throws: A read or decode error of either file.
    public init(name: String) throws {
        let directory = Self.directory
        let (requestData, questionData) = try blockingCall(.fileIO) {
            (try Data(contentsOf: directory.appendingPathComponent("\(name).request.json")),
             try Data(contentsOf: directory.appendingPathComponent("\(name).json")))
        }
        self.name = name
        request = try AgentQuestionJSON(data: requestData)
        question = try JSONDecoder().decode(AgentQuestion.self, from: questionData)
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
