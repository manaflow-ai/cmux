import Foundation
import Testing
@testable import CmuxMobileChief

/// CMUX-40: delete your only Cloud Chief, tap New Chief, and the deleted Chief came back with its
/// whole conversation. The phone makes an account's first chief with the fixed key `chief-default`,
/// and the owner answers a key it has seen with that create's stored result: the deleted chief's
/// id and main conversation, `archived_at` still null. New Chief must make a new one.
@Suite(.serialized) struct ChiefCreateReplayTests {
    static let deleted = "agent_01JDELETEDCHIEF00000000000"
    static let fresh = "agent_01JNEWCHIEF000000000000000"

    /// The owner: `chief-default` replays the deleted chief's create; any other key makes `fresh`.
    /// `chief.list` lists `fresh` once it was made, and `kept` (a chief another device made first).
    final class Owner: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var keys: [String] = []
        nonisolated(unsafe) static var made = false
        nonisolated(unsafe) static var kept: String?
        static let lock = NSLock()

        static func chief(_ id: String) -> String {
            #"{"id":"\#(id)","display_name":"Chief","is_default":true,"main_conversation":"conv_\#(id)","rev":1,"archived_at":null}"#
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let data = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let body: String = Self.lock.withLock {
                if object["op"] as? String == "chief.list" {
                    let ids = (Self.made ? [ChiefCreateReplayTests.fresh] : []) + (Self.kept.map { [$0] } ?? [])
                    let tombstone = #"{"id":"\#(ChiefCreateReplayTests.deleted)","owner_user":"user_1","archived_at":"2026-11-09T00:00:00Z"}"#
                    return #"{"ok":true,"value":{"chiefs":[\#(ids.map(Self.chief).joined(separator: ","))],"tombstones":[\#(tombstone)]}}"#
                }
                let key = object["idempotency_key"] as? String ?? ""
                Self.keys.append(key)
                let name = (object["params"] as? [String: Any])?["display_name"] as? String
                if key == "chief-default", name != "Chief" {
                    return #"{"error":{"code":"idempotency.conflict","message":"idempotency key reused with different params"}}"#
                }
                if key == "chief-default" { return #"{"ok":true,"value":\#(Self.chief(Self.kept ?? ChiefCreateReplayTests.deleted))}"# }
                Self.made = true
                return #"{"ok":true,"value":\#(Self.chief(ChiefCreateReplayTests.fresh))}"#
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, // crash-allow: test stub
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static func read(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }

        static func reset(kept: String? = nil) {
            lock.withLock {
                keys = []
                made = false
                self.kept = kept
            }
        }
    }

    private func http() -> ChiefCloudHTTP {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Owner.self]
        return ChiefCloudHTTP(base: URL(string: "https://cloud-api-staging.cmux.dev")!, // crash-allow: test literal
                              accessToken: { _ in "token" }, session: URLSession(configuration: configuration))
    }

    @Test func newChiefAfterDeletingTheOnlyOneNeverReopensTheDeletedOne() async throws {
        Owner.reset()
        let chief = try await ChiefSources.create(http(), displayName: "Chief", first: true)
        #expect(chief.id == Self.fresh)
        #expect(chief.mainConversation == "conv_\(Self.fresh)", "a new conversation, not the deleted chief's history")
        let keys = Owner.lock.withLock { Owner.keys }
        #expect(keys.first == "chief-default")
        #expect(keys.count == 2 && keys.last?.hasPrefix("chief-create-") == true)
    }

    @Test func anotherNameThanTheDeletedChiefsStillMakesANewOne() async throws {
        Owner.reset()
        let chief = try await ChiefSources.create(http(), displayName: "Research", first: true)
        #expect(chief.id == Self.fresh, "the key's refusal for other params is no reason to fail New Chief")
        let keys = Owner.lock.withLock { Owner.keys }
        #expect(keys.count == 2 && keys.last?.hasPrefix("chief-create-") == true)
    }

    @Test func theFirstChiefAnotherDeviceMadeIsStillShared() async throws {
        Owner.reset(kept: "agent_01JOTHERDEVICE0000000000000")
        let chief = try await ChiefSources.create(http(), displayName: "Chief", first: true)
        #expect(chief.id == "agent_01JOTHERDEVICE0000000000000", "`chief-default` still keeps two devices to one first chief")
        #expect(Owner.lock.withLock { Owner.keys } == ["chief-default"])
    }
}
