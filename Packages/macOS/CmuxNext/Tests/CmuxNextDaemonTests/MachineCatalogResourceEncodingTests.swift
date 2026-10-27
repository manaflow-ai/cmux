#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
@testable import CmuxNextDaemon

struct MachineCatalogResourceEncodingTests {
    @Test func machineListHasNoAncestorSelectors() throws {
        #expect(try wireParams("machine.list", [:]) == [:])
    }

    @Test func machineGetKeepsOnlyItsMachineSelector() throws {
        let params: [String: JSONValue] = ["machine": .string("machine_00000000000000000000000000000001")]
        #expect(try wireParams("machine.get", params) == params)
        #expect(try wireParams("machine.get", [:]) == ["machine": .string("current")])
    }

    @Test func sessionListDefaultsOnlyItsMachineAncestor() throws {
        #expect(try wireParams("session.list", [:]) == ["machine": .string("current")])
    }

    @Test func sessionResourcesKeepDefaultsAndExplicitSelectors() throws {
        #expect(try wireParams("workspace.list", [:]) == ["machine": .string("current"), "session": .string("current")])
        let params: [String: JSONValue] = ["machine": .string("owner"), "session": .string("session:chosen")]
        #expect(try wireParams("workspace.list", params) == params)
    }

    @Test func unsupportedExplicitSelectorsReachNativeValidation() throws {
        let params: [String: JSONValue] = ["machine": .string("unexpected"), "session": .string("unexpected")]
        #expect(try wireParams("machine.list", params) == params)
    }

    @Test(arguments: ["machine.list", "machine.get", "session.list", "workspace.list", "workspace.rename"])
    func confirmationDigestMatchesEncodedParams(_ operation: String) throws {
        let params: [String: JSONValue] = operation == "workspace.rename"
            ? ["workspace": .string("chosen"), "name": .string("A / 日本語")]
            : [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(wireParams(operation, params))
        let actualWireDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(try ResourceRelayClient.paramsDigest(params, operation: operation) == actualWireDigest)
    }

    @Test func legacyDigestPreservesSessionScopedConfirmations() throws {
        let params: [String: JSONValue] = ["workspace": .string("chosen"), "name": .string("renamed")]
        #expect(try ResourceRelayClient.paramsDigest(params) == ResourceRelayClient.paramsDigest(params, operation: "workspace.rename"))
        #expect(try ResourceRelayClient.paramsDigest([:], operation: "machine.list") != ResourceRelayClient.paramsDigest([:]))
    }

    private func wireParams(_ operation: String, _ params: [String: JSONValue]) throws -> [String: JSONValue] {
        let request = ResourceRequestEnvelope(id: 7, operation: operation, params: params)
        let json = try JSONDecoder().decode(JSONValue.self, from: request.line())
        guard case .object(let fields)? = json["params"] else {
            throw DaemonError.malformedResponse("resource request params")
        }
        #expect(json["protocol"] == .string("cmux.protocol/2"))
        #expect(json["operation"] == .string(operation))
        return fields
    }
}
