import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Web Inspector session routing")
struct SimulatorWebInspectorSessionRouterTests {
    @Test("Target-based mode wraps queued commands and unwraps responses")
    func targetBasedRouting() throws {
        var router = SimulatorWebInspectorSessionRouter()
        let command = Data(#"{"id":1,"method":"Runtime.evaluate","params":{"expression":"1+1"}}"#.utf8)
        #expect(try router.routeOutgoing(command).isEmpty)

        let created = Data(#"{"method":"Target.targetCreated","params":{"targetInfo":{"type":"page","targetId":"INNER"}}}"#.utf8)
        let creationResult = router.routeIncoming(created)
        let wrappedData = try #require(creationResult.messagesForTarget.first)
        let wrapped = try Self.object(wrappedData)
        #expect(wrapped["method"] as? String == "Target.sendMessageToTarget")
        let parameters = try #require(wrapped["params"] as? [String: Any])
        #expect(parameters["targetId"] as? String == "INNER")
        #expect(parameters["message"] as? String == String(decoding: command, as: UTF8.self))

        let acknowledgement = try Self.acknowledgement(for: wrappedData)
        #expect(router.routeIncoming(acknowledgement).messagesForHost.isEmpty)
        let dispatched = Data(#"{"method":"Target.dispatchMessageFromTarget","params":{"message":"{\"id\":1,\"result\":{\"result\":{\"value\":2}}}"}}"#.utf8)
        let unwrapped = router.routeIncoming(dispatched)
        #expect(unwrapped.messagesForHost.count == 1)
        #expect(try Self.object(unwrapped.messagesForHost[0])["id"] as? Int == 1)
    }

    @Test("String-id wrapper acknowledgements cannot escape before the inner response")
    func stringIdentifierAcknowledgement() throws {
        var router = SimulatorWebInspectorSessionRouter()
        _ = router.selectTargetBasedMode(targetIdentifier: "INNER")
        let command = Data(#"{"id":"abc","method":"Runtime.evaluate"}"#.utf8)
        let wrapped = try #require(try router.routeOutgoing(command).first)

        let acknowledgement = try Self.acknowledgement(for: wrapped)
        #expect(router.routeIncoming(acknowledgement).messagesForHost.isEmpty)
        let dispatched = Data(
            #"{"method":"Target.dispatchMessageFromTarget","params":{"message":"{\"id\":\"abc\",\"result\":{\"value\":2}}"}}"#.utf8
        )
        let response = router.routeIncoming(dispatched)
        #expect(response.messagesForHost.count == 1)
        #expect(try Self.object(response.messagesForHost[0])["id"] as? String == "abc")
    }

    @Test("Inner responses win when they arrive before numeric or string wrapper acknowledgements")
    func responseBeforeAcknowledgement() throws {
        for identifier in ["17", #""abc""#] {
            var router = SimulatorWebInspectorSessionRouter()
            _ = router.selectTargetBasedMode(targetIdentifier: "INNER")
            let command = Data("{\"id\":\(identifier),\"method\":\"Runtime.evaluate\"}".utf8)
            let wrapped = try #require(try router.routeOutgoing(command).first)

            let inner = "{\"id\":\(identifier),\"result\":{\"value\":2}}"
            let envelope: [String: Any] = [
                "method": "Target.dispatchMessageFromTarget",
                "params": ["message": inner],
            ]
            let dispatched = try JSONSerialization.data(withJSONObject: envelope)
            let response = router.routeIncoming(dispatched)
            #expect(response.messagesForHost.count == 1)

            let acknowledgement = try Self.acknowledgement(for: wrapped)
            #expect(router.routeIncoming(acknowledgement).messagesForHost.isEmpty)
        }
    }

    @Test("Target wrapper acknowledgements are bounded and reset recovers capacity")
    func acknowledgementBacklogCapAndReset() throws {
        var router = SimulatorWebInspectorSessionRouter()
        _ = router.selectTargetBasedMode(targetIdentifier: "INNER")
        for identifier in 0..<SimulatorWebInspectorSessionRouter.maximumWrappedAcknowledgementCount {
            let command = Data("{\"id\":\(identifier),\"method\":\"Runtime.enable\"}".utf8)
            #expect(try router.routeOutgoing(command).count == 1)
        }
        #expect(throws: SimulatorWebInspectorError.wrapperAcknowledgementBacklog(
            SimulatorWebInspectorSessionRouter.maximumWrappedAcknowledgementCount
        )) {
            _ = try router.routeOutgoing(Data(
                #"{"id":99999,"method":"Runtime.enable"}"#.utf8
            ))
        }

        router.reset()
        _ = router.selectTargetBasedMode(targetIdentifier: "INNER")
        #expect(try router.routeOutgoing(Data(
            #"{"id":1,"method":"Runtime.enable"}"#.utf8
        )).count == 1)
    }

    @Test("Queued replacement-target commands reserve wrapper acknowledgement capacity")
    func queuedCommandsReserveAcknowledgementCapacity() throws {
        var router = SimulatorWebInspectorSessionRouter()
        _ = router.selectTargetBasedMode(targetIdentifier: "OLD")
        for identifier in 0..<(SimulatorWebInspectorSessionRouter.maximumWrappedAcknowledgementCount - 1) {
            _ = try router.routeOutgoing(Data(
                "{\"id\":\(identifier),\"method\":\"Runtime.enable\"}".utf8
            ))
        }
        _ = router.routeIncoming(Data(
            #"{"method":"Target.targetDestroyed","params":{"targetId":"OLD"}}"#.utf8
        ))
        #expect(try router.routeOutgoing(Data(
            #"{"id":"queued","method":"Runtime.enable"}"#.utf8
        )).isEmpty)
        #expect(throws: SimulatorWebInspectorError.wrapperAcknowledgementBacklog(
            SimulatorWebInspectorSessionRouter.maximumWrappedAcknowledgementCount
        )) {
            _ = try router.routeOutgoing(Data(
                #"{"id":"overflow","method":"Runtime.enable"}"#.utf8
            ))
        }

        let replacement = router.routeIncoming(Data(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"type":"page","targetId":"NEW"}}}"#.utf8
        ))
        #expect(replacement.messagesForTarget.count == 1)
    }

    @Test("Duplicate request ids retain one wrapper acknowledgement per send")
    func duplicateIdentifierAcknowledgements() throws {
        var router = SimulatorWebInspectorSessionRouter()
        _ = router.selectTargetBasedMode(targetIdentifier: "INNER")
        let command = Data(#"{"id":"same","method":"Runtime.evaluate"}"#.utf8)
        let firstWrapper = try #require(try router.routeOutgoing(command).first)
        let secondWrapper = try #require(try router.routeOutgoing(command).first)
        #expect(try Self.object(firstWrapper)["id"] as? String
            != (try Self.object(secondWrapper)["id"] as? String))

        let inner = #"{"id":"same","result":{"value":1}}"#
        let dispatched = try JSONSerialization.data(withJSONObject: [
            "method": "Target.dispatchMessageFromTarget",
            "params": ["message": inner],
        ])
        #expect(router.routeIncoming(dispatched).messagesForHost.count == 1)
        let firstAcknowledgement = try Self.acknowledgement(for: firstWrapper)
        let secondAcknowledgement = try Self.acknowledgement(for: secondWrapper)
        #expect(router.routeIncoming(firstAcknowledgement).messagesForHost.isEmpty)
        #expect(router.routeIncoming(secondAcknowledgement).messagesForHost.isEmpty)
        #expect(router.routeIncoming(firstAcknowledgement).messagesForHost.count == 1)
    }

    @Test("Direct Target commands cannot collide with outstanding wrapper identifiers")
    func directTargetIdentifierCollision() throws {
        var router = SimulatorWebInspectorSessionRouter()
        _ = router.selectTargetBasedMode(targetIdentifier: "INNER")
        let wrapped = try #require(try router.routeOutgoing(Data(
            #"{"id":1,"method":"Runtime.enable"}"#.utf8
        )).first)
        let wrapperID = try #require(try Self.object(wrapped)["id"] as? String)
        let direct = try JSONSerialization.data(withJSONObject: [
            "id": wrapperID,
            "method": "Target.getTargets",
        ])
        #expect(throws: SimulatorWebInspectorError.wrapperIdentifierCollision) {
            _ = try router.routeOutgoing(direct)
        }
    }

    @Test("A direct Target command may reuse the embedded user id before the wrapper ack")
    func directTargetMayReuseUserIdentifier() throws {
        var router = SimulatorWebInspectorSessionRouter()
        _ = router.selectTargetBasedMode(targetIdentifier: "INNER")
        let wrapped = try #require(try router.routeOutgoing(Data(
            #"{"id":"user-id","method":"Runtime.enable"}"#.utf8
        )).first)
        let dispatched = try JSONSerialization.data(withJSONObject: [
            "method": "Target.dispatchMessageFromTarget",
            "params": ["message": #"{"id":"user-id","result":{}}"#],
        ])
        #expect(router.routeIncoming(dispatched).messagesForHost.count == 1)

        let direct = Data(#"{"id":"user-id","method":"Target.getTargets"}"#.utf8)
        #expect(try router.routeOutgoing(direct) == [direct])
        let directResponse = Data(#"{"id":"user-id","result":{"targetInfos":[]}}"#.utf8)
        #expect(router.routeIncoming(directResponse).messagesForHost == [directResponse])

        let delayedAcknowledgement = try Self.acknowledgement(for: wrapped)
        #expect(router.routeIncoming(delayedAcknowledgement).messagesForHost.isEmpty)
    }

    @Test("Cross-origin target replacement updates subsequent wrappers")
    func provisionalTargetReplacement() throws {
        var router = SimulatorWebInspectorSessionRouter()
        _ = router.routeIncoming(Data(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"type":"page","targetId":"OLD"}}}"#.utf8
        ))
        _ = router.routeIncoming(Data(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"newTargetId":"NEW"}}"#.utf8
        ))
        let routed = try #require(try router.routeOutgoing(
            Data(#"{"id":2,"method":"DOM.getDocument","params":{}}"#.utf8)
        ).first)
        let parameters = try #require(try Self.object(routed)["params"] as? [String: Any])
        #expect(parameters["targetId"] as? String == "NEW")
    }

    @Test("An explicit legacy probe response releases queued commands")
    func legacySignal() throws {
        var router = SimulatorWebInspectorSessionRouter()
        let command = Data(#"{"id":3,"method":"Console.enable","params":{}}"#.utf8)
        #expect(try router.routeOutgoing(command).isEmpty)
        #expect(router.selectLegacyMode() == [command])
        #expect(router.mode == .legacy)
    }

    @Test("Queued commands enforce count and byte caps")
    func queueCaps() throws {
        var router = SimulatorWebInspectorSessionRouter()
        for identifier in 0..<SimulatorWebInspectorSessionRouter.maximumQueuedCommandCount {
            let command = Data("{\"id\":\(identifier),\"method\":\"Runtime.enable\"}".utf8)
            #expect(try router.routeOutgoing(command).isEmpty)
        }
        #expect(throws: SimulatorWebInspectorError.self) {
            _ = try router.routeOutgoing(Data(#"{"id":99,"method":"Runtime.enable"}"#.utf8))
        }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        return try #require(value as? [String: Any])
    }

    private static func acknowledgement(for wrapper: Data) throws -> Data {
        let identifier = try #require(try object(wrapper)["id"])
        return try JSONSerialization.data(withJSONObject: ["id": identifier, "result": [:]])
    }
}
