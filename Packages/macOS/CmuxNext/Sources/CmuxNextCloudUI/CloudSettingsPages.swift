public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// What the Settings page's Cloud cards ask the app (`cmux.settings.environments.*`,
/// `cmux.settings.cloud.allotment.get`), answered here so the app target only routes the op.
extension CloudEnvironmentsSettings {
    /// `cmux.settings.environments.state`: the state is read here, encoded off the main actor.
    public func pageState() async -> JSONValue {
        await Self.pageValue(state) ?? .null
    }

    /// `cmux.settings.environments.run`: the params decode and the answer encodes off the main actor.
    public func runPage(_ params: JSONValue) async throws -> JSONValue {
        guard let run = await Self.runRequest(params) else {
            throw PageError.invalidParams("unknown environments action")
        }
        let result = await self.run(run)
        return await Self.pageValue(result) ?? .object([:])
    }

    @concurrent nonisolated private static func pageValue(_ value: some Encodable & Sendable) async -> JSONValue? {
        try? JSONValue.parse(JSONEncoder().encode(value))
    }

    @concurrent nonisolated private static func runRequest(_ params: JSONValue) async -> CloudEnvironmentsRun? {
        try? JSONDecoder().decode(CloudEnvironmentsRun.self, from: JSONSerialization.data(withJSONObject: params.foundationObject))
    }
}

/// Settings > Cloud > Compute (Labs `labs.teamCompute`): the team's allotment as the platform sends it,
/// the Cloud app server's `cloud.allotment.get` answer passed through. Only the read is served, so the
/// card is read-only.
///
/// The switch off, signed out, or any failure (allotments are off for the team:
/// `cmux.cloud.allotment_off`) is one refusal; the page reads it as no view and draws the card's
/// unavailable line.
@MainActor
public struct CloudAllotmentPage {
    private let available: @MainActor () -> Bool
    private let get: @MainActor () async throws -> Data

    /// `available`: the Labs switch is on and the person is signed in to Cloud. `get`:
    /// `cloud.allotment.get`'s answer as JSON.
    public init(available: @escaping @MainActor () -> Bool, get: @escaping @MainActor () async throws -> Data) {
        self.available = available
        self.get = get
    }

    /// `cmux.settings.cloud.allotment.get`.
    public func read() async throws -> JSONValue {
        guard available() else { throw Self.unavailable }
        // A null answer (the app's Cloud went away mid-read) is no view either.
        guard let view = try? JSONValue.parse(await get()), view != .null else { throw Self.unavailable }
        return view
    }

    static let unavailable = PageError(code: "cmux.page.unavailable", message: "team compute is unavailable")
}
