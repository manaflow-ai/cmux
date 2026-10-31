import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AgentPanePromptUploadMetaTests {
    private let uploadId = "019c6e27-e55b-73d1-87d8-4e01f1f75043"

    private func block(_ type: String = "image") -> [String: Any] {
        var value: [String: Any] = [
            "type": type, "name": "original.pem",
            "_meta": ["acpmux": ["upload": ["uploadId": uploadId, "fileName": "original.pem"]]],
        ]
        if type == "resource_link" { value["uri"] = "acpmux-upload:\(uploadId)" }
        return value
    }

    private func relayed(_ blocks: [[String: Any]]) throws -> [String: Any] {
        let frame: [String: Any] = [
            "jsonrpc": "2.0", "id": 17, "method": "session/prompt",
            "params": ["sessionId": "chat", "prompt": blocks,
                       "_meta": ["acpmux": ["promptId": "prompt"], "cmuxGesture": "ticket"]],
        ]
        let output = AcpmuxPaneMethods.strippingPromptMeta(frame) ?? frame
        let bytes = try JSONSerialization.data(withJSONObject: output)
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    @Test(arguments: ["image", "resource_link"])
    func uploadReferenceSurvivesRelay(type: String) throws {
        let output = try relayed([block(type)])
        #expect(output["id"] as? Int == 17)
        let params = try #require(output["params"] as? [String: Any])
        #expect(params["sessionId"] as? String == "chat")
        let requestMeta = try #require(params["_meta"] as? [String: Any])
        #expect(requestMeta["cmuxGesture"] as? String == "ticket")
        #expect((requestMeta["acpmux"] as? [String: Any])?["promptId"] as? String == "prompt")
        let blocks = try #require(params["prompt"] as? [[String: Any]])
        let meta = try #require(blocks.first?["_meta"] as? [String: Any])
        let acpmux = try #require(meta["acpmux"] as? [String: Any])
        #expect(acpmux["upload"] as? [String: String] == ["uploadId": uploadId, "fileName": "original.pem"])
        #expect(blocks.first?["data"] == nil)
    }

    @Test func unrelatedAndNestedMetadataNeverSurvives() throws {
        var value = block()
        value["_meta"] = ["untrusted": true, "acpmux": [
            "context": "spoof", "upload": ["uploadId": uploadId, "fileName": "original.pem"],
        ]]
        value["annotations"] = ["_meta": ["acpmux": ["upload": ["uploadId": uploadId, "fileName": "nested"]]]]
        let output = try relayed([value, ["type": "text", "text": "hello", "_meta": ["context": true]]])
        let params = try #require(output["params"] as? [String: Any])
        let blocks = try #require(params["prompt"] as? [[String: Any]])
        let meta = try #require(blocks[0]["_meta"] as? [String: Any])
        #expect(Set(meta.keys) == ["acpmux"])
        #expect(Set((meta["acpmux"] as? [String: Any] ?? [:]).keys) == ["upload"])
        #expect((blocks[0]["annotations"] as? [String: Any])?["_meta"] == nil)
        #expect(blocks[1]["_meta"] == nil)
    }

    @Test func malformedOrByteCarryingReferencesLoseMetadata() throws {
        var values: [[String: Any]] = []
        for type in ["text", "resource", "audio"] {
            var value = block(); value["type"] = type; values.append(value)
        }
        var wrongURI = block("resource_link"); wrongURI["uri"] = "acpmux-upload:another"; values.append(wrongURI)
        var imageURI = block(); imageURI["uri"] = "file:///private/file"; values.append(imageURI)
        for field in ["data", "blob", "resource"] {
            var value = block(); value[field] = "bytes"; values.append(value)
        }
        for (id, name) in [("", "original.pem"), ("not-an-id", "original.pem"), (uploadId, "")] {
            var value = block(); value["_meta"] = ["acpmux": ["upload": ["uploadId": id, "fileName": name]]]; values.append(value)
        }
        var owned = block(); owned["_meta"] = ["acpmux": ["upload": ["uploadId": uploadId, "fileName": "original.pem", "owned": true]]]; values.append(owned)
        let output = try relayed(values)
        let params = try #require(output["params"] as? [String: Any])
        let blocks = try #require(params["prompt"] as? [[String: Any]])
        #expect(blocks.count == values.count)
        #expect(blocks.allSatisfy { $0["_meta"] == nil })
    }
}
