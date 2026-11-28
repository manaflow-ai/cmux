package import CmuxNextPages
package import CmuxNextSettings
import Foundation

/// `cmux.chief.backend.*` of the Chief editor (Home's New Chief and Edit Chief page, Settings >
/// Chief > Chiefs; docs/chiefs-create-byo-backend.md): the acpmux harnesses a Chief may run on,
/// adding one the person brings, and the real hello turn before the Chief record takes it. Thin:
/// every call runs on the harness owner, the one path the `agent.harness.*` actions and
/// Settings > Agents use.
///
/// - `list`: `{harnesses: _acpmux/harnesses, models: _acpmux/models | null}`.
/// - `add {kind, name, id?, replace?, command, args | baseUrl, model, apiKey?}`, on a click only, passed to acpmux's
///   add (`replace` only when it names the same id; acpmux refuses an id it has before any key is stored). `{id}`.
/// - `doctor {id, chief?}`: `_acpmux/harness/doctor {id, prompt: true, chief: true, chiefId?}`, `{ok, steps}`.
@MainActor
package final class ChiefBackendPageRoute: PageProvider {
    nonisolated package static let prefix = "cmux.chief.backend."

    private let harnesses: any ChiefBackendHarnesses
    private let personOnly: @MainActor () -> String
    private var spentGesture: TimeInterval?

    package init(harnesses: any ChiefBackendHarnesses, personOnly: @escaping @MainActor () -> String) {
        self.harnesses = harnesses
        self.personOnly = personOnly
    }

    package func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        do {
            switch op {
            case Self.prefix + "list":
                let listed = try await harnesses.harnessList()
                // An acpmux without the model probe still lists its harnesses.
                let models = (try? await harnesses.models()) ?? .null
                return ["harnesses": listed, "models": models]
            case Self.prefix + "add":
                guard context.userGesture, let event = context.gestureEvent, event != spentGesture else {
                    throw PageError(code: PageNativeOp.userOnlyCode, message: personOnly())
                }
                spentGesture = event
                let backend = try BroughtChiefBackend(params)
                return ["id": .string(try await harnesses.addChiefBackend(backend))]
            case Self.prefix + "doctor":
                guard let id = params["id"]?.stringValue, !id.isEmpty else { throw PageError.invalidParams("id is required") }
                return try await harnesses.doctorChiefBackend(id: id, extra: params["chief"]?.stringValue.flatMap { $0.isEmpty ? nil : ["chief": true, "chiefId": $0] as [String: any Sendable] } ?? ["chief": true])
            default:
                throw PageError.unknownOp(op)
            }
        } catch let error as PageError {
            throw error
        } catch {
            throw harnesses.chiefBackendError(error)
        }
    }
}

@MainActor
package protocol ChiefBackendHarnesses: AnyObject {
    func harnessList() async throws -> JSONValue
    func models() async throws -> JSONValue
    func addChiefBackend(_ backend: BroughtChiefBackend) async throws -> String
    func doctorChiefBackend(id: String, extra: [String: any Sendable]) async throws -> JSONValue
    func chiefBackendError(_ error: any Error) -> PageError
}
