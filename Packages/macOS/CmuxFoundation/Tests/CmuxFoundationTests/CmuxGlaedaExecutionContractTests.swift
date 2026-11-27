import Foundation
import Testing
@testable import CmuxFoundation

@Suite("CMUX Glaeda execution contract")
struct CmuxGlaedaExecutionContractTests {
    private let contract = CmuxGlaedaExecutionContract()

    private var request: CmuxGlaedaExecutionRequest {
        CmuxGlaedaExecutionRequest(
            externalRequestRef: "cmux:exec:1050:fixture-1",
            workRef: "cmux:work:1050",
            repository: "teamleaderleo/glaeda",
            commit: "0409c2f4e82385d0770bb2b34f34fd3e6e2dbc36",
            tree: "03613a93ce152aefddbb246613084705043b1397"
        )
    }

    private var exactRequest: String {
        #"{"correlation":{"work_ref":"cmux:work:1050"},"document_type":"glaeda-external-execution-request","external_request_ref":"cmux:exec:1050:fixture-1","operation":"verify_focused","requested_capability_class":"credentialless_project","reuse_hint":"prefer_valid_reuse","schema_version":1,"source":{"commit":"0409c2f4e82385d0770bb2b34f34fd3e6e2dbc36","repository":"teamleaderleo/glaeda","tree":"03613a93ce152aefddbb246613084705043b1397"}}"# + "\n"
    }

    private var exactReceipt: String {
        #"{"authority":{"authorizes_cleanup":false,"authorizes_execution":false,"authorizes_host_selection":false,"authorizes_redispatch":false},"correlation":{"work_ref":"cmux:work:1050"},"document_type":"glaeda-external-execution-receipt","external_request_ref":"cmux:exec:1050:fixture-1","operation":"verify_focused","refusal_code":null,"request_sha256":"sha256:c10e23961f34eaabb979f890ce830efeca737ef63f4534f0b8cf9346fadf9d60","resolved_workload":{"capability_class":"credentialless_project","generation":"sha256:5c4664ac2da3dcc66826d111a5f82e5614b9589dbbbdcf4383b6a88cd38a1195","id":"verify-focused/v1"},"schema_version":1,"source":{"commit":"0409c2f4e82385d0770bb2b34f34fd3e6e2dbc36","repository":"teamleaderleo/glaeda","tree":"03613a93ce152aefddbb246613084705043b1397"},"state":"planned","workload_receipt_sha256":null}"# + "\n"
    }

    @Test("request encoding matches the Glaeda fixture exactly")
    func requestEncoding() throws {
        let encoded = try contract.encodeRequest(request)
        #expect(encoded == Data(exactRequest.utf8))
        #expect(try contract.decodeRequest(encoded) == request)
    }

    @Test("planned receipt correlates to CMUX work")
    func plannedReceipt() throws {
        let observation = try contract.observe(
            requestData: Data(exactRequest.utf8),
            receiptData: Data(exactReceipt.utf8)
        )
        #expect(observation.externalRequestRef == request.externalRequestRef)
        #expect(observation.workRef == request.workRef)
        #expect(observation.state == "planned")
        #expect(observation.requestSHA256 == "sha256:c10e23961f34eaabb979f890ce830efeca737ef63f4534f0b8cf9346fadf9d60")
        #expect(observation.workloadReceiptSHA256 == nil)
    }

    @Test("numeric authority lookalike is refused")
    func numericAuthority() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(exactReceipt.utf8)) as? [String: Any]
        )
        var authority = try #require(object["authority"] as? [String: Any])
        authority["authorizes_execution"] = 0
        object["authority"] = authority
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)

        #expect(throws: CmuxGlaedaExecutionContractError.invalidReceipt) {
            _ = try contract.observe(requestData: Data(exactRequest.utf8), receiptData: data)
        }
    }

    @Test("false terminal receipt without workload evidence is refused")
    func falseTerminal() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(exactReceipt.utf8)) as? [String: Any]
        )
        object["state"] = "succeeded"
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)

        #expect(throws: CmuxGlaedaExecutionContractError.terminalEvidenceMissing) {
            _ = try contract.observe(requestData: Data(exactRequest.utf8), receiptData: data)
        }
    }

    @Test("terminal receipt with bounded evidence is accepted")
    func terminalEvidence() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(exactReceipt.utf8)) as? [String: Any]
        )
        object["state"] = "succeeded"
        object["workload_receipt_sha256"] = "sha256:" + String(repeating: "b", count: 64)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
        let observation = try contract.observe(
            requestData: Data(exactRequest.utf8),
            receiptData: data
        )
        #expect(observation.state == "succeeded")
        #expect(observation.workloadReceiptSHA256 == "sha256:" + String(repeating: "b", count: 64))
    }

    @Test("source and request digest drift are refused")
    func drift() throws {
        var sourceDrift = try #require(
            JSONSerialization.jsonObject(with: Data(exactReceipt.utf8)) as? [String: Any]
        )
        var source = try #require(sourceDrift["source"] as? [String: Any])
        source["tree"] = String(repeating: "f", count: 40)
        sourceDrift["source"] = source
        let sourceData = try JSONSerialization.data(withJSONObject: sourceDrift, options: [.sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
        #expect(throws: CmuxGlaedaExecutionContractError.invalidReceipt) {
            _ = try contract.observe(requestData: Data(exactRequest.utf8), receiptData: sourceData)
        }

        var digestDrift = try #require(
            JSONSerialization.jsonObject(with: Data(exactReceipt.utf8)) as? [String: Any]
        )
        digestDrift["request_sha256"] = "sha256:" + String(repeating: "f", count: 64)
        let digestData = try JSONSerialization.data(withJSONObject: digestDrift, options: [.sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
        #expect(throws: CmuxGlaedaExecutionContractError.requestDigestMismatch) {
            _ = try contract.observe(requestData: Data(exactRequest.utf8), receiptData: digestData)
        }
    }

    @Test("oversized and noncanonical documents fail closed")
    func boundsAndCanonicality() throws {
        #expect(throws: CmuxGlaedaExecutionContractError.documentTooLarge("receipt")) {
            _ = try contract.observe(
                requestData: Data(exactRequest.utf8),
                receiptData: Data(repeating: 0x20, count: CmuxGlaedaExecutionContract.maxDocumentBytes + 1)
            )
        }

        let object = try JSONSerialization.jsonObject(with: Data(exactReceipt.utf8))
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        #expect(throws: CmuxGlaedaExecutionContractError.noncanonicalJSON("receipt")) {
            _ = try contract.observe(requestData: Data(exactRequest.utf8), receiptData: pretty)
        }
    }
}
