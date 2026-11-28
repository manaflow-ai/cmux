import CmuxNextSettings
import Foundation

/// `cloud.place.get {session}` → `{session, move}`: the chat's last move as Rust's place reducer drew it (its `View`:
/// `state`, `step`, `elapsedMs` and `steps`, each finished step's ms; the app's ``CloudPlaceFlows/moveView(of:)``), `move`
/// null with none kept. A move action's success carries no answer, so this is how the move journey probe
/// (cmuxterm-hq cloud_journeys_probe.py) splits a move's time into its steps (`move_stages_ms`). A read of this app's own state.
public struct CloudPlaceControl {
    public init() {}
    public static let name = "cloud.place.get"

    public static func method(_ view: @escaping @MainActor @Sendable (_ session: String) -> Any?) -> ControlMethod {
        .mainActor(name) { call in .value(try reply(call.params, view: view)) }
    }

    @MainActor static func reply(_ params: [String: JSONValue], view: (String) -> Any?) throws -> JSONValue {
        guard let session = params["session"]?.stringValue, !session.isEmpty else { throw ControlError.invalidParams("needs session") }
        return .object(["session": .string(session), "move": view(session).flatMap(JSONValue.init(foundation:)) ?? .null])
    }
}
