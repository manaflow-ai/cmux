import Foundation
import Testing
@testable import CmuxNextDaemon

struct VaultEnvWireTests {
    @Test func requestCarriesTheEnvelopeAndParamsVerbatimAndNeverDescribesTheValue() throws {
        let params: JSONValue = .object(["name": .string("OPENAI_API_KEY"), "value": .string("sk-value"),
                                         "delivery": .string("proxy"), "allowedHosts": .array([.string("api.openai.com")])])
        let request = VaultEnvRequest(action: "set", params: params, platformOrigin: "https://platform.example", accessToken: "install-secret")
        let fields = try JSONDecoder().decode(JSONValue.self, from: try WireCoding.encodeRequest(request, id: 1))
        #expect(fields["cmd"] == .string("vault-env"))
        #expect(fields["action"] == .string("set"))
        #expect(fields["platform_origin"] == .string("https://platform.example"))
        #expect(fields["access_token"] == .string("install-secret"))
        #expect(fields["params"] == params) // allowedHosts stays camelCase
        #expect(VaultEnvRequest.requiredCapability == "vault-env-v1")
        let described = String(describing: request)
        #expect(!described.contains("install-secret") && !described.contains("sk-value") && !described.contains("OPENAI"))
    }

    @Test func listAnswerKeepsCamelCaseKeys() throws {
        let line = Data(#"{"id":1,"ok":true,"data":{"entries":[{"name":"GH_TOKEN","revision":3,"updatedAt":1764000000000,"delivery":"proxy","allowedHosts":["api.github.com"]}]}}"#.utf8)
        let answer = try WireCoding.decodeResponse(VaultEnvRequest.Response.self, from: line)
        let entry = answer["entries"]?.arrayValue?.first
        #expect(entry?["updatedAt"] == .number(1764000000000))
        #expect(entry?["allowedHosts"] == .array([.string("api.github.com")]))
    }
}
