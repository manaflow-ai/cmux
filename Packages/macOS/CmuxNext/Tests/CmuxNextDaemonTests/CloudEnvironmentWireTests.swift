import Foundation
import Testing
@testable import CmuxNextDaemon

struct CloudEnvironmentWireTests {
    @Test func requestPreservesPlatformKeysAndUsesSnakeCaseForTheEnvelope() throws {
        let params: JSONValue = .object(["id": .string("env_default"), "patch": .object([
            "setup_script": .null,
            "set_secrets": .array([.object(["name": .string("MY_TOKEN"), "value": .string("secret")])]),
            "env_vars": .array([.object(["name": .string("CamelCase_ENV"), "value": .string("value")])]),
            "opaqueKey": .object(["doNotRewrite": .string("value")]),
        ])])
        let request = CloudEnvironmentRequest(action: "update", params: params,
                                              platformOrigin: "https://cmux-platform-development.debussy.workers.dev", accessToken: "install-secret")
        let line = try WireCoding.encodeRequest(request, id: 1)
        let fields = try JSONDecoder().decode(JSONValue.self, from: line)
        #expect(fields["cmd"] == .string("cloud-environment"))
        #expect(fields["platform_origin"] == .string("https://cmux-platform-development.debussy.workers.dev"))
        #expect(fields["access_token"] == .string("install-secret"))
        #expect(fields["params"] == params)
        #expect(!String(describing: request).contains("install-secret"))
        #expect(!String(describing: request).contains("MY_TOKEN"))
    }

    @Test func responsePreservesPlatformAndUserKeys() throws {
        let line = Data(#"{"id":1,"ok":true,"data":{"is_default":true,"setup_script":null,"secrets":[{"name":"MY_TOKEN","updated_at":"now"}],"env_vars":[{"name":"CamelCase_ENV","value":"value"}],"doNotRewrite":1}}"#.utf8)
        let response = try WireCoding.decodeResponse(CloudEnvironmentRequest.Response.self, from: line)
        #expect(response["is_default"] == .bool(true))
        #expect(response["setup_script"] == .null)
        #expect(response["secrets"] == .array([.object(["name": .string("MY_TOKEN"), "updated_at": .string("now")])]))
        #expect(response["env_vars"] == .array([.object(["name": .string("CamelCase_ENV"), "value": .string("value")])]))
        #expect(response["doNotRewrite"] == .number(1))
    }
}
