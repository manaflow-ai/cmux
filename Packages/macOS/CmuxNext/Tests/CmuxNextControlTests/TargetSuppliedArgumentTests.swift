import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `cmux space switch Work` (the form the help prints) sends `--target room:Work`, and the app answered
/// "space.switch requires --space": only `--space Work` switched. The catalog says a room target supplies the
/// `space` argument (`isSuppliedByTarget`), and the registry runs such a call from a menu
/// (`ActionRegistry.target(of:supplies:for:)`); the socket's check of required arguments did not know the rule.
@MainActor
@Suite struct TargetSuppliedArgumentTests {
    static func request(_ action: String, _ params: [String: JSONValue]) throws -> ControlActionRequest {
        let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == action })
        return try ControlRouter.validatedRequest(for: ArgumentActionContractTests.info(descriptor), params: params,
                                                  knownKinds: ActionTargetKind.allCases.map(\.rawValue),
                                                  connection: ControlConnectionID(rawValue: 1))
    }

    /// Every action whose required argument a target of its kind supplies runs with that target alone.
    @Test func aTargetOfTheArgumentsKindSuppliesIt() throws {
        var checked = 0
        for descriptor in ActionCatalog.all {
            for argument in descriptor.arguments where argument.isRequired && argument.isSuppliedByTarget {
                guard case .target(let kind) = argument.kind, descriptor.targets.contains(kind) else { continue }
                let others = descriptor.arguments.filter { $0.isRequired && $0.name != argument.name }
                guard others.isEmpty else { continue }
                checked += 1
                #expect(throws: Never.self, "\(descriptor.id.rawValue) --target \(kind.rawValue):Work") {
                    let request = try Self.request(descriptor.id.rawValue, ["target": .string("\(kind.rawValue):Work")])
                    #expect(request.target == ControlTargetRef(kind: kind.rawValue, id: "Work"))
                }
            }
        }
        #expect(checked > 0, "no action has an argument its target supplies")
        #expect(throws: Never.self) { try Self.request("space.switch", ["target": .string("room:Work")]) }
    }

    /// A target of another kind supplies nothing, and no target supplies nothing: the call is still refused.
    @Test func aCallThatNamesNoSpaceIsStillRefused() throws {
        #expect(throws: ControlError.self) { try Self.request("space.switch", [:]) }
        #expect(throws: ControlError.self) { try Self.request("space.switch", ["target": .string("window:win_1")]) }
        #expect(throws: Never.self) { try Self.request("space.switch", ["args": .object(["space": .string("Work")])]) }
    }
}
