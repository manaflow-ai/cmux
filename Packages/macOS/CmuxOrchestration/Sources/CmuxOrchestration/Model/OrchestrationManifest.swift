public import Foundation

/// The parsed `orchestration.json` manifest at the root of a template.
///
/// An orchestration template is a directory (usually a git repo) that
/// captures a whole way of running fleets of coding agents: prompts,
/// workspace shapes, agent commands, and provisioning style. The manifest is
/// the versioned index of that directory; everything else it names is a
/// template-relative file.
public struct OrchestrationManifest: Sendable, Hashable, Codable {
    /// The manifest schema revision this file was authored against.
    /// cmux refuses schemas newer than it understands.
    public var schemaVersion: Int
    /// Install name: lowercase slug, also the directory name under
    /// `~/.cmuxterm/orchestrations/`.
    public var name: String
    /// Template version (loose semver, `X[.Y[.Z]]`).
    public var version: String
    public var description: String
    public var author: String?
    /// Minimum cmux app version this template needs, if any.
    public var minCmuxVersion: String?
    /// Install-time interview questions. Resolved values live per-install on
    /// the user's machine, never in the template.
    public var parameters: [OrchestrationParameter]
    /// How task workspaces are provisioned.
    public var substrate: OrchestrationSubstrate
    /// Agent command templates. At least one is required.
    public var agents: [OrchestrationAgent]
    /// Agent id used when no step or override selects one. Defaults to the
    /// first declared agent.
    public var defaultAgent: String?
    /// Template-relative path of the prompt template used when `steps` is
    /// absent.
    public var prompt: String?
    /// Optional linear step chain (v1: linear only, no DAGs).
    public var steps: [OrchestrationStep]?
    /// Template-relative path of a cmux saved-layout JSON applied to each
    /// task workspace.
    public var layout: String?
    /// Template-relative path of the fleet workflow description
    /// (conventionally `WORKFLOW.md`).
    public var workflow: String?
    /// Template-relative paths of agent instruction fragments (CLAUDE.md /
    /// AGENTS.md additions).
    public var instructions: [String]?

    public static let currentSchemaVersion = 1
    public static let manifestFileName = "orchestration.json"

    public init(
        schemaVersion: Int = OrchestrationManifest.currentSchemaVersion,
        name: String,
        version: String,
        description: String,
        author: String? = nil,
        minCmuxVersion: String? = nil,
        parameters: [OrchestrationParameter] = [],
        substrate: OrchestrationSubstrate,
        agents: [OrchestrationAgent],
        defaultAgent: String? = nil,
        prompt: String? = nil,
        steps: [OrchestrationStep]? = nil,
        layout: String? = nil,
        workflow: String? = nil,
        instructions: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.minCmuxVersion = minCmuxVersion
        self.parameters = parameters
        self.substrate = substrate
        self.agents = agents
        self.defaultAgent = defaultAgent
        self.prompt = prompt
        self.steps = steps
        self.layout = layout
        self.workflow = workflow
        self.instructions = instructions
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case name
        case version
        case description
        case author
        case minCmuxVersion
        case parameters
        case substrate
        case agents
        case defaultAgent
        case prompt
        case steps
        case layout
        case workflow
        case instructions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.name = try container.decode(String.self, forKey: .name)
        self.version = try container.decode(String.self, forKey: .version)
        self.description = try container.decode(String.self, forKey: .description)
        self.author = try container.decodeIfPresent(String.self, forKey: .author)
        self.minCmuxVersion = try container.decodeIfPresent(String.self, forKey: .minCmuxVersion)
        self.parameters = try container.decodeIfPresent([OrchestrationParameter].self, forKey: .parameters) ?? []
        self.substrate = try container.decode(OrchestrationSubstrate.self, forKey: .substrate)
        self.agents = try container.decode([OrchestrationAgent].self, forKey: .agents)
        self.defaultAgent = try container.decodeIfPresent(String.self, forKey: .defaultAgent)
        self.prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        self.steps = try container.decodeIfPresent([OrchestrationStep].self, forKey: .steps)
        self.layout = try container.decodeIfPresent(String.self, forKey: .layout)
        self.workflow = try container.decodeIfPresent(String.self, forKey: .workflow)
        self.instructions = try container.decodeIfPresent([String].self, forKey: .instructions)
    }

    /// Template names are lowercase slugs: ASCII letters, digits, and
    /// hyphens, starting and ending with an alphanumeric.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, let last = name.last else { return false }
        guard first.isASCII, last.isASCII, first.isLetter || first.isNumber, last.isLetter || last.isNumber else {
            return false
        }
        return name.allSatisfy { character in
            character.isASCII
                && ((character.isLowercase && character.isLetter) || character.isNumber || character == "-")
        }
    }

    /// The agent used when nothing more specific is selected: the declared
    /// default, else the first step's agent, else the first declared agent.
    public var effectiveDefaultAgent: OrchestrationAgent? {
        if let defaultAgent, let match = agents.first(where: { $0.id == defaultAgent }) {
            return match
        }
        if let firstStep = steps?.first, let match = agents.first(where: { $0.id == firstStep.agent }) {
            return match
        }
        return agents.first
    }

    public func agent(withID id: String) -> OrchestrationAgent? {
        agents.first { $0.id == id }
    }
}

/// Manifest parsing failure with a message suitable for CLI output.
public struct OrchestrationManifestError: Error, Sendable, Hashable, CustomStringConvertible {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Parses `orchestration.json` data with actionable error messages and
/// unknown-key detection (unknown top-level keys are reported so typos like
/// `defualtAgent` don't silently disappear).
public enum OrchestrationManifestParser {
    public struct Output: Sendable {
        public var manifest: OrchestrationManifest
        /// Top-level keys present in the JSON that the schema does not know.
        public var unknownKeys: [String]
    }

    public static func parse(data: Data) throws -> Output {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OrchestrationManifestError(
                message: "orchestration.json is not valid JSON: \(error.localizedDescription)"
            )
        }
        guard let dictionary = object as? [String: Any] else {
            throw OrchestrationManifestError(message: "orchestration.json must be a JSON object")
        }

        if let schemaVersion = dictionary["schemaVersion"] as? Int,
           schemaVersion > OrchestrationManifest.currentSchemaVersion {
            throw OrchestrationManifestError(
                message: "orchestration.json uses schemaVersion \(schemaVersion), but this cmux only "
                    + "understands up to \(OrchestrationManifest.currentSchemaVersion). Update cmux to use this template."
            )
        }

        let manifest: OrchestrationManifest
        do {
            manifest = try JSONDecoder().decode(OrchestrationManifest.self, from: data)
        } catch let error as DecodingError {
            throw OrchestrationManifestError(message: Self.describe(error))
        }

        let knownKeys = Set(OrchestrationManifest.CodingKeys.allCases.map(\.stringValue))
        let unknownKeys = dictionary.keys.filter { !knownKeys.contains($0) }.sorted()
        return Output(manifest: manifest, unknownKeys: unknownKeys)
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let joined = context.codingPath.map(\.stringValue).joined(separator: ".")
            return joined.isEmpty ? "top level" : joined
        }
        switch error {
        case .keyNotFound(let key, let context):
            let parent = path(context)
            return "orchestration.json is missing required key '\(key.stringValue)' at \(parent)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "orchestration.json has a wrong value at \(path(context)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "orchestration.json is invalid at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return "orchestration.json failed to decode: \(error.localizedDescription)"
        }
    }
}
