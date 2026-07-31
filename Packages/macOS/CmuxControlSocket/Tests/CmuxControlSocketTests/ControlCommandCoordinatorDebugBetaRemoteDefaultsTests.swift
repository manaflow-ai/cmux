import Foundation
import Testing

@testable import CmuxControlSocket

#if DEBUG
@MainActor
@Suite("ControlCommandCoordinator beta remote-default debug dispatch")
struct ControlCommandCoordinatorDebugBetaRemoteDefaultsTests {
    @Test func getReturnsTypedResolutionReadback() {
        let context = FakeBetaRemoteDefaultControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(
            ControlRequest(
                id: .int(1),
                method: "debug.beta_remote_defaults.get",
                params: ["key": .string("tests.beta.enabled")]
            )
        )

        #expect(result == .ok(.object([
            "setting_id": .string("tests.beta.enabled"),
            "flag_key": .string("tests-beta-default-experiment"),
            "user_key_present": .bool(false),
            "user_value": .null,
            "remote_default": .bool(true),
            "effective_value": .bool(true),
            "source": .string("remoteDefault"),
        ])))
    }

    @Test func setAcceptsNullAsCacheClearAndRejectsOtherTypes() {
        let context = FakeBetaRemoteDefaultControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let cleared = coordinator.handle(
            ControlRequest(
                id: .int(1),
                method: "debug.beta_remote_defaults.set",
                params: [
                    "key": .string("tests.beta.enabled"),
                    "value": .null,
                ]
            )
        )
        #expect(context.lastValueWasSet)
        #expect(context.lastValue == nil)
        guard case .ok = cleared else {
            Issue.record("expected cache clear to succeed")
            return
        }

        guard case .err(let code, _, let data) = coordinator.handle(
            ControlRequest(
                id: .int(2),
                method: "debug.beta_remote_defaults.set",
                params: [
                    "key": .string("tests.beta.enabled"),
                    "value": .string("true"),
                ]
            )
        ) else {
            Issue.record("expected invalid value to fail")
            return
        }
        #expect(code == "invalid_params")
        #expect(data == nil)
    }

    @Test func validationErrorsUseContextProvidedStrings() {
        let context = FakeBetaRemoteDefaultControlCommandContext()
        context.strings = ControlDebugBetaRemoteDefaultStrings(
            missingKey: "localized missing key",
            notFound: "localized not found",
            missingValue: "localized missing value",
            invalidValue: "localized invalid value"
        )
        let coordinator = ControlCommandCoordinator(context: context)

        guard case .err(_, let missingKey, _) = coordinator.handle(
            ControlRequest(
                id: .int(1),
                method: "debug.beta_remote_defaults.get",
                params: [:]
            )
        ) else {
            Issue.record("expected missing-key error")
            return
        }
        guard case .err(_, let invalidValue, _) = coordinator.handle(
            ControlRequest(
                id: .int(2),
                method: "debug.beta_remote_defaults.set",
                params: [
                    "key": .string("tests.beta.enabled"),
                    "value": .string("true"),
                ]
            )
        ) else {
            Issue.record("expected invalid-value error")
            return
        }
        #expect(missingKey == "localized missing key")
        #expect(invalidValue == "localized invalid value")
    }
}

@MainActor
private final class FakeBetaRemoteDefaultControlCommandContext: ControlCommandContext {
    var lastValueWasSet = false
    var lastValue: Bool?
    var strings = ControlDebugBetaRemoteDefaultStrings(
        missingKey: "Missing key",
        notFound: "Beta remote default not found",
        missingValue: "Missing value",
        invalidValue: "value must be a bool or null"
    )

    func controlDebugBetaRemoteDefaultStrings() -> ControlDebugBetaRemoteDefaultStrings {
        strings
    }

    func controlDebugBetaRemoteDefaultSnapshot(
        identifier: String
    ) -> ControlDebugBetaRemoteDefaultSnapshot? {
        snapshot(remoteDefault: true)
    }

    func controlDebugSetBetaRemoteDefault(
        identifier: String,
        value: Bool?
    ) -> ControlDebugBetaRemoteDefaultSnapshot? {
        lastValueWasSet = true
        lastValue = value
        return snapshot(remoteDefault: value)
    }

    private func snapshot(
        remoteDefault: Bool?
    ) -> ControlDebugBetaRemoteDefaultSnapshot {
        ControlDebugBetaRemoteDefaultSnapshot(
            settingID: "tests.beta.enabled",
            flagKey: "tests-beta-default-experiment",
            userKeyPresent: false,
            userValue: nil,
            remoteDefault: remoteDefault,
            effectiveValue: remoteDefault ?? false,
            source: remoteDefault == nil ? "compileDefault" : "remoteDefault"
        )
    }
}
#endif
