import CmuxNextDaemonService
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// `cmux.chief.backend.*` of the Chief editor (Home's New Chief and Edit Chief page, Settings >
/// Chief > Chiefs; docs/chiefs-create-byo-backend.md): the acpmux harnesses a Chief may run on,
/// adding one the person brings, and the real hello turn before the Chief record takes it. Thin:
/// every call runs on ``AgentHarnessCenter``, the one path the `agent.harness.*` actions and
/// Settings > Agents use.
///
/// - `list`: `{harnesses: _acpmux/harnesses, models: _acpmux/models | null}`.
/// - `add {kind, name, id?, replace?, command, args | baseUrl, model, apiKey?}`, on a click only, passed to acpmux's
///   add (`replace` only when it names the same id; acpmux refuses an id it has before any key is stored). `{id}`.
/// - `doctor {id}`: `_acpmux/harness/doctor {id, prompt: true}`, `{ok, steps}`. `remove {id}`: only an id added here.
@MainActor
final class ChiefBackendPageRoute: PageProvider {
    nonisolated static let prefix = "cmux.chief.backend."
    private let center: AgentHarnessCenter
    private var spentGesture: TimeInterval?, added: Set<String> = []

    init(center: AgentHarnessCenter) { self.center = center }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        do {
            switch op {
            case Self.prefix + "list":
                // An acpmux without the model probe still lists its harnesses.
                return ["harnesses": try await center.harnessList(), "models": (try? await center.models()) ?? .null]
            case Self.prefix + "add":
                guard context.userGesture, let event = context.gestureEvent, event != spentGesture else {
                    throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
                }
                spentGesture = event
                let backend = try BroughtChiefBackend(params)
                return ["id": .string(added.insert(try await add(backend)).memberAfterInsert)]
            case Self.prefix + "remove":
                guard let id = params["id"]?.stringValue, added.remove(id) != nil else { throw PageError.invalidParams("not added here") }
                return try await center.remove(id: id)
            case Self.prefix + "doctor":
                guard let id = params["id"]?.stringValue, !id.isEmpty else { throw PageError.invalidParams("id is required") }
                return try await center.doctor(id: id)
            default:
                throw PageError.unknownOp(op)
            }
        } catch let error as PageError {
            throw error
        } catch {
            throw PageError(code: "cmux.agents.\(AgentHarnessCenter.code(error))", message: AgentHarnessCenter.text(error))
        }
    }

    /// One acpmux add (it checks the id, writes the profile and stores the key in one locked step).
    private func add(_ backend: BroughtChiefBackend) async throws -> String {
        var request = AgentHarnessAddRequest()
        request.id = backend.id
        request.displayName = backend.name
        request.replace = backend.replace
        switch backend.kind {
        case .command(let command, let args):
            request.command = command
            request.args = args
        case .endpoint(let example, let baseURL, let model, let apiKey):
            request.example = example
            request.baseURL = baseURL
            request.model = model
            request.apiKey = apiKey
        }
        return try await center.add(request)["id"]?.stringValue ?? backend.id
    }
}

/// A backend the person brings, as the page sends it (`cmux.chief.backend.add`).
nonisolated struct BroughtChiefBackend: Equatable {
    enum Kind: Equatable {
        case command(String, args: [String])
        /// `example` is `anthropic-endpoint` or `openai-endpoint`; an empty `apiKey` sends none.
        case endpoint(example: String, baseURL: String, model: String, apiKey: String)
    }

    var id, name: String
    var kind: Kind
    var replace = false

    init(_ params: JSONValue) throws {
        let text = { (key: String) in params[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        name = text("name")
        guard !name.isEmpty else { throw PageError.invalidParams("name is required") }
        id = Self.id(for: text("id").isEmpty ? name : text("id"))
        replace = params["replace"]?.stringValue == id
        switch text("kind") {
        case "command":
            guard !text("command").isEmpty else { throw PageError.invalidParams("command is required") }
            kind = .command(text("command"), args: params["args"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        case let example where example == "anthropic-endpoint" || example == "openai-endpoint":
            let baseURL = text("baseUrl")
            guard let url = URL(string: baseURL), url.scheme == "https" || url.scheme == "http", url.host != nil else {
                throw PageError.invalidParams("baseUrl must be an http or https URL")
            }
            guard !text("model").isEmpty else { throw PageError.invalidParams("model is required") }
            let apiKey = params["apiKey"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            kind = .endpoint(example: example, baseURL: baseURL, model: text("model"), apiKey: apiKey)
        default:
            throw PageError.invalidParams("kind must be command, anthropic-endpoint or openai-endpoint")
        }
    }

    /// A profile id from the name: lowercase letters, digits and dashes (`My Backend` -> `my-backend`).
    static func id(for name: String) -> String {
        var id = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                id.unicodeScalars.append(scalar)
            } else if !id.isEmpty, !id.hasSuffix("-") {
                id.append("-")
            }
        }
        while id.count > 40 || id.hasSuffix("-") { id.removeLast() }
        return id.isEmpty ? "my-backend" : id
    }
}
