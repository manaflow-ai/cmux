import CmuxNextCloud
public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// What the Settings page's Cloud cards ask the app (`cmux.settings.environments.*`,
/// `cmux.settings.cloud.allotment.get` and `.set`), answered here so the app target only routes the op.
extension CloudEnvironmentsSettings {
    /// `cmux.settings.environments.state`.
    // main-actor-ok: the Cloud settings page state, a few small fields
    public var pageState: JSONValue { (try? JSONValue.parse(JSONEncoder().encode(state))) ?? .null }

    /// `cmux.settings.environments.run`.
    public func runPage(_ params: JSONValue) async throws -> JSONValue {
        // main-actor-ok: one page action's params, a few small fields
        guard let run = try? JSONDecoder().decode(CloudEnvironmentsRun.self, from: JSONSerialization.data(withJSONObject: params.foundationObject)) else {
            throw PageError.invalidParams("unknown environments action")
        }
        // main-actor-ok: one page action's small result
        return (try? JSONValue.parse(JSONEncoder().encode(await self.run(run)))) ?? .object([:])
    }
}

/// Settings > Cloud > Compute (Labs `labs.teamCompute`): the team's allotment as the platform sends it,
/// the Cloud app server's `cloud.allotment.get` answer passed through, and its `cloud.allotment.set`
/// (only the team's hold for its people; the server checks the args and refuses everything else).
///
/// The switch off, signed out, or any failure of the read (allotments are off for the team:
/// `cmux.cloud.allotment_off`) is one refusal; the page reads it as no view and draws the card's
/// unavailable line. A refused set keeps the server's own sentence (``refusedCode``), which the
/// card shows under the control.
@MainActor
public struct CloudAllotmentPage {
    /// `cloud.allotment.set` with the page's params as JSON args; its answer as JSON.
    public typealias Write = @MainActor (_ args: Data) async throws -> Data

    private let available: @MainActor () -> Bool
    private let get: @MainActor () async throws -> Data
    private let set: Write?

    /// `available`: the Labs switch is on and the person is signed in to Cloud. `get`:
    /// `cloud.allotment.get`'s answer as JSON. `set`: `cloud.allotment.set`; nil serves only the read.
    public init(available: @escaping @MainActor () -> Bool, get: @escaping @MainActor () async throws -> Data,
                set: Write? = nil) {
        self.available = available
        self.get = get
        self.set = set
    }

    /// `cmux.settings.cloud.allotment.get`.
    public func read() async throws -> JSONValue {
        guard available() else { throw Self.unavailable }
        // A null answer (the app's Cloud went away mid-read) is no view either.
        guard let view = try? JSONValue.parse(await get()), view != .null else { throw Self.unavailable }
        return view
    }

    /// `cmux.settings.cloud.allotment.set`: the page's params passed through as the op's args (the
    /// server checks them); its answer passed back.
    public func write(_ params: JSONValue) async throws -> JSONValue {
        guard available(), let set else { throw Self.unavailable }
        do {
            return try JSONValue.parse(await set(JSONEncoder().encode(params)))
        } catch let failure as CloudAppOpFailure {
            throw PageError(code: Self.refusedCode, message: failure.description, retryable: failure.retryable,
                            details: .object(["code": .string(failure.code)]))
        }
    }

    static let unavailable = PageError(code: "cmux.page.unavailable", message: "team compute is unavailable")
    /// A set the Cloud app server refused: `message` is the server's sentence for the person, `details.code` its code.
    public static let refusedCode = "cmux.settings.cloud.allotment.refused"
}
