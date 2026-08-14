import Foundation
import Testing
@testable import CmuxClientConfig

@Suite(.serialized) struct ClientConfigTests {
    @Test func decodesFlagValuesAndPayloads() throws {
        let data = Data("""
        {
          "featureFlags": {
            "cmux-for-windows": true,
            "pricing-copy": "enterprise"
          },
          "featureFlagPayloads": {
            "pricing-copy": {
              "headline": "Ship faster",
              "seats": 12,
              "trial": true
            }
          },
          "errorsWhileComputingFlags": false,
          "requestId": "req-1"
        }
        """.utf8)

        let config = try JSONDecoder().decode(ClientConfig.self, from: data)

        #expect(config.value(.cmuxForWindows) == true)
        #expect(config.value(ClientConfigFlag<String?>(variantKey: "pricing-copy")) == "enterprise")
        #expect(config.featureFlagPayloads["pricing-copy"]?.objectValue?["headline"]?.stringValue == "Ship faster")
    }

    @Test func typedFlagsFallBackOnMissingOrMismatchedValues() {
        let config = ClientConfig(
            featureFlags: [
                "cmux-for-windows": .variant("beta"),
                "pricing-copy": .bool(true),
            ],
            featureFlagPayloads: [:],
            errorsWhileComputingFlags: false
        )

        #expect(config.value(.cmuxForWindows) == false)
        #expect(config.value(ClientConfigFlag<String?>(variantKey: "pricing-copy")) == nil)
        #expect(config.value(ClientConfigFlag<String?>(variantKey: "missing", defaultValue: "control")) == "control")
    }

    @Test func decodesTypedPayloads() throws {
        let config = ClientConfig(
            featureFlags: [:],
            featureFlagPayloads: [
                "pricing-copy": .object([
                    "headline": .string("Ship faster"),
                    "seats": .number(12),
                ]),
            ],
            errorsWhileComputingFlags: false
        )

        let payload = try config.payload(ClientConfigPayloadFlag<PricingPayload>(key: "pricing-copy"))
        #expect(payload == PricingPayload(headline: "Ship faster", seats: 12))
    }

    @Test func typedPayloadsFallBackOnMissingOrMismatchedValues() throws {
        let fallback = PricingPayload(headline: "Fallback", seats: 1)
        let config = ClientConfig(
            featureFlags: [:],
            featureFlagPayloads: [
                "pricing-copy": .string("{\"headline\":\"Keep as text\"}"),
            ],
            errorsWhileComputingFlags: false
        )

        let mismatchedPayload = try config.payload(ClientConfigPayloadFlag<PricingPayload>(
            key: "pricing-copy",
            defaultValue: fallback
        ))
        let missingPayload = try config.payload(ClientConfigPayloadFlag<PricingPayload>(
            key: "missing",
            defaultValue: fallback
        ))

        #expect(mismatchedPayload == fallback)
        #expect(missingPayload == fallback)
    }

    @Test func encodesRequestContextWithoutEmptyBuckets() throws {
        let request = ClientConfigRequest(
            distinctId: "user-1",
            context: ClientConfigEvaluationContext(
                personProperties: ["platform": .string("ios"), "build": .string("123")],
                anonDistinctId: "anon-1",
                evaluationContexts: ["mobile"]
            )
        )

        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        let context = object?["context"] as? [String: Any]

        #expect(object?["distinctId"] as? String == "user-1")
        #expect(context?["personProperties"] != nil)
        #expect(context?["groups"] == nil)
        #expect(context?["anonDistinctId"] as? String == "anon-1")
        #expect(context?["evaluationContexts"] as? [String] == ["mobile"])
    }

    @Test func httpLoaderPostsToClientConfigRoute() async throws {
        RecordingClientConfigURLProtocol.recorder.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingClientConfigURLProtocol.self]
        let loader = HTTPClientConfigLoader(
            apiBaseURL: "https://cmux.test/",
            session: URLSession(configuration: configuration)
        )

        let config = try await loader.load(ClientConfigRequest(distinctId: "user-1"))

        #expect(config.value(.cmuxForWindows) == true)
        let request = RecordingClientConfigURLProtocol.recorder.requests.first
        #expect(request?.url?.absoluteString == "https://cmux.test/api/client-config")
        #expect(request?.httpMethod == "POST")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
    }
}
