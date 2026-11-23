import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `auth.handoff.mint` / `auth.handoff.redeem` (`cmux auth handoff`): routing only. The requests
/// and their rules are cmux-tui's `cli/cloud_auth_handoff_relay.rs` (tested there).
@MainActor
@Suite struct AuthHandoffMethodTests {
    @MainActor private final class Seen {
        var calls: [(op: String, params: JSONValue?)] = []
    }

    private func methods(disabled: Set<ActionFeature> = [], seen: Seen, answer: String) -> [String: ControlMethod] {
        let list = ControlMethod.authHandoff(disabledFeatures: { disabled }, relay: { op, request in
            let params = (try? JSONSerialization.jsonObject(with: request)).flatMap { JSONValue(foundation: $0) }
            await MainActor.run { seen.calls.append((op, params)) }
            return Data(answer.utf8)
        })
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }

    private func run(_ method: ControlMethod?, _ params: [String: JSONValue]) async throws -> JSONValue {
        guard case .async(let body)? = method?.body else {
            Issue.record("not an async method")
            return .null
        }
        let call = ControlCall(request: ControlRequest(id: "1", method: method?.name ?? "", params: params),
                               snapshot: BrowserOpenSplitTests.snapshot(), connection: ControlConnectionID(rawValue: 1),
                               deadline: .now + .seconds(20), progress: ControlCallProgress())
        return try await body(call)
    }

    @Test func eachMethodSendsItsOpAndParamsAndAnswersTheValue() async throws {
        let seen = Seen()
        let methods = methods(seen: seen, answer: #"{"ok":true,"value":{"code":"cmh_x"}}"#)
        #expect(try await run(methods["auth.handoff.mint"], ["device": .string("air")]) == .object(["code": .string("cmh_x")]))
        #expect(try await run(methods["auth.handoff.redeem"], ["code": .string("cmh_y")]) == .object(["code": .string("cmh_x")]))
        #expect(seen.calls.map(\.op) == ["mint", "redeem"])
        #expect(seen.calls.map(\.params) == [.object(["device": .string("air")]), .object(["code": .string("cmh_y")])])
    }

    @Test func aRefusalKeepsTheCodeTheCLIMapsToAnExitCode() async {
        let methods = methods(seen: Seen(), answer: #"{"ok":false,"error":{"code":"other_user","message":"another account"}}"#)
        for name in ["auth.handoff.mint", "auth.handoff.redeem"] {
            await #expect(throws: ControlError(code: "other_user", message: "another account")) { try await run(methods[name], [:]) }
        }
    }

    @Test func anAnswerThatIsNoAnswerIsUnavailable() {
        for line in ["", "not json", #"{"ok":true}"#, #"{"ok":false}"#] {
            #expect(throws: ControlError.self) { try ControlMethod.authHandoffAnswer(Data(line.utf8)) }
            #expect((try? ControlMethod.authHandoffAnswer(Data(line.utf8))) == nil)
        }
        do {
            _ = try ControlMethod.authHandoffAnswer(Data("{}".utf8))
        } catch let error as ControlError {
            #expect(error.code == "unavailable")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func bothMethodsAreOffWithCloudAndSendNothing() async {
        #expect(ActionFeature(controlMethod: "auth.handoff.mint") == .cloud)
        #expect(ActionFeature(controlMethod: "auth.handoff.redeem") == .cloud)
        let seen = Seen()
        let methods = methods(disabled: [.cloud], seen: seen, answer: #"{"ok":true,"value":{}}"#)
        for name in ["auth.handoff.mint", "auth.handoff.redeem"] {
            await #expect(throws: ControlError.self) { try await run(methods[name], [:]) }
        }
        #expect(seen.calls.isEmpty)
    }
}
