import Foundation
import Testing

@testable import CMUXMobileCore

@Suite("Analytics wire contract")
struct AnalyticsWireContractTests {
    @Test func encodesTheProxyShapeAndAliasesAnonymousIdentity() throws {
        let event = AnalyticsWireEvent(
            name: "ios_terminal_input_submitted",
            properties: ["byte_count": .int(12), "is_paste": .bool(false)],
            distinctID: "install-1",
            anonymousID: "install-1",
            timestamp: Date(timeIntervalSince1970: 0)
        )

        let data = try AnalyticsWireBatch(events: [event]).encodedData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let batch = try #require(object["batch"] as? [[String: Any]])
        let wireEvent = try #require(batch.first)
        #expect(wireEvent["event"] as? String == "ios_terminal_input_submitted")
        #expect(wireEvent["distinct_id"] as? String == "install-1")
        #expect(wireEvent["timestamp"] as? String == "1970-01-01T00:00:00Z")
        let properties = try #require(wireEvent["properties"] as? [String: Any])
        #expect(properties["byte_count"] as? Int == 12)
        #expect(properties["is_paste"] as? Bool == false)
        #expect(properties["$anon_distinct_id"] as? String == "install-1")
    }

    @Test func rejectsNamesTheServerCannotForward() {
        let event = AnalyticsWireEvent(name: "ios_private_payload")
        #expect(throws: AnalyticsWireError.eventNameNotAllowed("ios_private_payload")) {
            try AnalyticsWireContract.validate(event)
        }
    }

    @Test func boundsPropertyValuesAndNumbers() {
        let longValue = String(repeating: "x", count: AnalyticsWireContract.maxStringValueBytes + 1)
        let long = AnalyticsWireEvent(name: "ios_app_launched", properties: ["value": .string(longValue)])
        #expect(throws: AnalyticsWireError.stringValueTooLong(property: "value", byteCount: longValue.utf8.count)) {
            try AnalyticsWireContract.validate(long)
        }

        let nan = AnalyticsWireEvent(name: "ios_app_launched", properties: ["value": .double(.nan)])
        #expect(throws: AnalyticsWireError.nonFiniteNumber(property: "value")) {
            try AnalyticsWireContract.validate(nan)
        }
    }

    @Test func rejectsOversizedBatchesBeforeEncoding() {
        let events = Array(
            repeating: AnalyticsWireEvent(name: "ios_app_launched"),
            count: AnalyticsWireContract.maxBatchEvents + 1
        )
        #expect(throws: AnalyticsWireError.batchCountExceeded(events.count)) {
            try AnalyticsWireBatch(events: events).encodedData()
        }
    }

    @Test func rejectsOversizedRequestAfterEncoding() {
        let value = String(repeating: "x", count: AnalyticsWireContract.maxStringValueBytes)
        let properties = Dictionary(
            uniqueKeysWithValues: (0..<AnalyticsWireContract.maxEventProperties).map {
                ("value_\($0)", AnalyticsValue.string(value))
            }
        )
        let events = Array(
            repeating: AnalyticsWireEvent(
                name: "ios_app_launched",
                properties: properties
            ),
            count: 5
        )
        #expect {
            try AnalyticsWireBatch(events: events).encodedData()
        } throws: { error in
            guard case let AnalyticsWireError.requestTooLarge(byteCount) = error else { return false }
            return byteCount > AnalyticsWireContract.maxRequestBytes
        }
    }
}
