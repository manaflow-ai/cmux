import Foundation
import Testing
@testable import CmuxReadAloud

@Suite struct ReadAloudConfigurationTests {
    @Test(arguments: [
        #"{"model":"unknown","voiceID":"voice","speed":1}"#,
        #"{"model":"speech-2.6-turbo","voiceID":"voice","speed":1}"#,
        #"{"model":"speech-2.8-turbo","voiceID":"","speed":1}"#,
        #"{"model":"speech-2.8-turbo","voiceID":"  ","speed":1}"#,
        #"{"model":"speech-2.8-turbo","voiceID":"voice\nID","speed":1}"#,
        #"{"model":"speech-2.8-turbo","voiceID":"voice\u0000ID","speed":1}"#,
        #"{"model":"speech-2.8-turbo","voiceID":"voice","speed":0.49}"#,
        #"{"model":"speech-2.8-hd","voiceID":"voice","speed":2.01}"#
    ])
    func rejectsInvalidPersistedConfiguration(_ json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ReadAloudConfiguration.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: ["speech-2.8-turbo", "speech-2.8-hd"], [0.5, 1.0, 2.0])
    func supportedConfigurationRoundTrips(model: String, speed: Double) throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "model": model, "voiceID": "custom_voice", "speed": speed
        ])
        let configuration = try JSONDecoder().decode(ReadAloudConfiguration.self, from: json)
        let encoded = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(ReadAloudConfiguration.self, from: encoded) == configuration)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["model"] as? String == model)
        #expect(object["voiceID"] as? String == "custom_voice")
        #expect(object["speed"] as? Double == speed)
    }
}
