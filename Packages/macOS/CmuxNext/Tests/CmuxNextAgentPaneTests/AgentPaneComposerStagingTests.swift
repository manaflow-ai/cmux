import AppKit
@testable import CmuxNextAgentPane
import CmuxNextWakeups
import CryptoKit
import Foundation
import Testing

/// Exercises the page request decoder, bounded staging writes, opaque references and recorded
/// pasteboard output. The platform clipboard is never changed.
@MainActor @Suite(.serialized)
struct AgentPaneComposerStagingTests {
    private nonisolated static let mib = 1 << 20
    private nonisolated static let chunkBytes = 256 << 10

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private final class Effects {
        var copied: [[NSPasteboardItem]] = []
    }

    private struct Payload {
        var name: String
        var size: Int
        var byte: UInt8
        var mimeType = "text/plain"
    }

    private static func fixture() throws -> (URL, AgentPaneModel, Effects) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("composer-staging-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AgentPaneModel(host: NoHost(), sessionId: "one")
        let effects = Effects()
        model.replyLinks.imageFolder = folder.appendingPathComponent("copies", isDirectory: true)
        model.replyLinks.copyWork = BackgroundWork(label: "test.composer-staging")
        model.replyLinks.copyItems = { effects.copied.append($0); return true }
        model.replyLinks.copyItem = { _ in Issue.record("staged composer copy used the single-item clipboard route"); return false }
        return (folder, model, effects)
    }

    private static func ask(_ model: AgentPaneModel, _ method: String, _ params: [String: Any]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    private static func value(_ reply: [String: Any]) throws -> [String: Any] {
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        return try #require(reply["value"] as? [String: Any])
    }

    private static func failed(_ reply: [String: Any]) -> Bool { reply["ok"] as? Bool == false }

    /// Sends only one reusable, bounded fixture, updating the oracle from the bytes actually sent.
    private static func stage(_ model: AgentPaneModel, _ payload: Payload, index: Int,
                              manifest: [[String: Any]], batch: inout String?, contents: Data? = nil) async throws -> (reference: String, hash: [UInt8]) {
        var params: [String: Any] = ["name": "copy-\(index)", "size": payload.size]
        if let batch { params["batchToken"] = batch } else { params["batch"] = manifest }
        let begun = try value(await ask(model, "composer.copy.begin", params))
        let token = try #require(begun["token"] as? String)
        #expect(UUID(uuidString: token) != nil)
        #expect((begun["chunkSize"] as? Int ?? 0) >= chunkBytes)
        batch = begun["batchToken"] as? String ?? batch
        let chunk = contents ?? Data(repeating: payload.byte, count: chunkBytes)
        let encoded = chunk.base64EncodedString()
        var hash = SHA256()
        for offset in stride(from: 0, to: payload.size, by: chunkBytes) {
            let count = min(chunkBytes, payload.size - offset)
            let bytes = chunk.prefix(count)
            let answer = try value(await ask(model, "composer.copy.chunk", [
                "token": token, "offset": offset, "data": count == chunk.count ? encoded : Data(bytes).base64EncodedString(),
            ]))
            #expect(answer["offset"] as? Int == offset + count)
            hash.update(data: bytes)
        }
        let finished = try value(await ask(model, "composer.copy.finish", ["token": token]))
        let reference = try #require(finished["reference"] as? String)
        #expect(UUID(uuidString: reference) != nil)
        #expect(!reference.contains("/"))
        return (reference, Array(hash.finalize()))
    }

    /// Reads the published file in bounded blocks, including its last byte in the digest.
    @concurrent private static func digest(_ file: URL) async throws -> (size: Int, hash: [UInt8]) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256(), size = 0
        while let bytes = try handle.read(upToCount: chunkBytes), !bytes.isEmpty {
            size += bytes.count
            hash.update(data: bytes)
        }
        return (size, Array(hash.finalize()))
    }

    private static func manifest(_ payloads: [Payload]) -> [[String: Any]] {
        payloads.enumerated().map { ["name": "copy-\($0.offset)", "size": $0.element.size] }
    }

    private static func regularFiles(in folder: URL) -> Set<URL> {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        let entries = enumerator?.allObjects as? [URL] ?? []
        return Set(entries.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { $0.resolvingSymlinksInPath() })
    }

    /// A complete small staged copy, including the web path's separate ordering metadata.
    private static func smallStagedCopy(_ model: AgentPaneModel) async throws -> [String: Any] {
        let payloads = [Payload(name: "selection", size: 4, byte: 0x73), Payload(name: "order", size: 2, byte: 0),
                        Payload(name: "one.txt", size: 4, byte: 0x61)]
        let manifest = Self.manifest(payloads)
        model.transport.gestures.record()
        var batch: String?
        let text = try await Self.stage(model, payloads[0], index: 0, manifest: manifest, batch: &batch)
        let order = try await Self.stage(model, payloads[1], index: 1, manifest: manifest, batch: &batch, contents: Data("[]".utf8))
        let file = try await Self.stage(model, payloads[2], index: 2, manifest: manifest, batch: &batch)
        return ["text": text.reference, "order": order.reference, "items": [
            ["name": "one.txt", "mimeType": "text/plain", "reference": file.reference],
        ]]
    }

    @Test func aLargeCopyKeepsEveryByteAndEveryItemInOrder() async throws {
        let (folder, model, effects) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        // These staged bytes remain local clipboard copies even when the agent runs elsewhere.
        model.remoteChat = true
        let selection = Payload(name: "selection", size: 9 * Self.mib, byte: 0x73)
        let payloads = [selection,
                        Payload(name: "large.bin", size: 33 * Self.mib, byte: 0xa7, mimeType: "application/octet-stream"),
                        Payload(name: "large.txt", size: 9 * Self.mib, byte: 0x62)]
            + (0..<126).map { Payload(name: "file-\($0).txt", size: Self.mib, byte: UInt8(65 + $0 % 26)) }
        let manifest = Self.manifest(payloads)
        model.transport.gestures.record()
        var batch: String?
        var staged: [(reference: String, hash: [UInt8])] = []
        for (index, payload) in payloads.enumerated() {
            staged.append(try await Self.stage(model, payload, index: index, manifest: manifest, batch: &batch))
        }
        let attachments: [[String: Any]] = payloads.dropFirst().enumerated().map { index, payload in
            ["name": payload.name, "mimeType": payload.mimeType, "reference": staged[index + 1].reference]
        }
        let params: [String: Any] = ["text": staged[0].reference, "items": attachments]
        let copied = try Self.value(await Self.ask(model, "composer.copy.staged", params))
        #expect(copied["copied"] as? Int == 128)
        #expect(copied["skipped"] as? Int == 0)
        let board = try #require(effects.copied.first)
        #expect(effects.copied.count == 1)
        #expect(board.count == 129)
        let text = try #require(board.first?.string(forType: .string))
        #expect(text.utf8.count == selection.size)
        #expect(text.utf8.allSatisfy { $0 == selection.byte })
        let copyID = try #require(copied["copyID"] as? String)
        #expect(UUID(uuidString: copyID) != nil)
        #expect(board[0].string(forType: .html)?.contains("data-cmux-composer-copy=\"\(copyID)\"") == true)
        let names = try #require(copied["files"] as? [[String: Any]])
        #expect(names.compactMap { $0["item"] as? Int } == Array(0..<128))
        #expect(names.compactMap { $0["name"] as? String } == payloads.dropFirst().map(\.name))
        var total = 0
        for (index, item) in board.dropFirst().enumerated() {
            let payload = payloads[index + 1]
            let file = try #require(item.string(forType: .fileURL).flatMap(URL.init(string:)))
            #expect(file.lastPathComponent == payload.name)
            let actual = try await Self.digest(file)
            #expect(actual.size == payload.size, "\(payload.name)")
            #expect(actual.hash == staged[index + 1].hash, "\(payload.name)")
            total += actual.size
        }
        #expect(total == 168 * Self.mib)
        // Consuming the opaque references cannot authorize a second clipboard replacement.
        #expect(Self.failed(await Self.ask(model, "composer.copy.staged", params)))
        #expect(effects.copied.count == 1)
    }

    @Test func aSessionSwitchInvalidatesLiveStagesBatchesAndCompletedReferences() async throws {
        let (folder, model, effects) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let payloads = [Payload(name: "selection", size: 4, byte: 0x73), Payload(name: "one.txt", size: 4, byte: 0x61),
                        Payload(name: "live", size: 4, byte: 0x62), Payload(name: "later", size: 4, byte: 0x63)]
        let manifest = Self.manifest(payloads)
        model.transport.gestures.record()
        var batch: String?
        let text = try await Self.stage(model, payloads[0], index: 0, manifest: manifest, batch: &batch)
        let file = try await Self.stage(model, payloads[1], index: 1, manifest: manifest, batch: &batch)
        let batchToken = try #require(batch)
        let live = try Self.value(await Self.ask(model, "composer.copy.begin", ["name": "copy-2", "size": 4, "batchToken": batchToken]))
        let token = try #require(live["token"] as? String)
        let (otherFolder, otherModel, otherEffects) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: otherFolder) }
        #expect(Self.failed(await Self.ask(otherModel, "composer.copy.staged", ["text": text.reference, "items": [
            ["name": "one.txt", "mimeType": "text/plain", "reference": file.reference],
        ]])))
        #expect(otherEffects.copied.isEmpty)
        model.adoptSession("two")
        #expect(Self.failed(await Self.ask(model, "composer.copy.chunk", ["token": token, "offset": 0, "data": Data([1, 2, 3, 4]).base64EncodedString()])))
        #expect(Self.failed(await Self.ask(model, "composer.copy.finish", ["token": token])))
        #expect(Self.failed(await Self.ask(model, "composer.copy.begin", ["name": "copy-3", "size": 4, "batchToken": batchToken])))
        #expect(Self.failed(await Self.ask(model, "composer.copy.staged", ["text": text.reference, "items": [
            ["name": "one.txt", "mimeType": "text/plain", "reference": file.reference],
        ]])))
        #expect(effects.copied.isEmpty)
    }

    @Test func cancellingTakesBackBothAnIncompleteStageAndACompletedReference() async throws {
        let (folder, model, effects) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let payloads = [Payload(name: "selection", size: 0, byte: 0x73), Payload(name: "one.txt", size: 4, byte: 0x61),
                        Payload(name: "live", size: 4, byte: 0x62)]
        let manifest = Self.manifest(payloads)
        // No page script can start filling the local clipboard cache without a real gesture.
        #expect(Self.failed(await Self.ask(model, "composer.copy.begin", ["name": "copy-0", "size": 0, "batch": manifest])))
        model.transport.gestures.record()
        var batch: String?
        let text = try await Self.stage(model, payloads[0], index: 0, manifest: manifest, batch: &batch)
        let file = try await Self.stage(model, payloads[1], index: 1, manifest: manifest, batch: &batch)
        let live = try Self.value(await Self.ask(model, "composer.copy.begin", [
            "name": "copy-2", "size": 4, "batchToken": try #require(batch),
        ]))
        let token = try #require(live["token"] as? String)
        #expect(Self.failed(await Self.ask(model, "composer.copy.finish", ["token": token])))
        let stageCancelled = await Self.ask(model, "composer.copy.cancel", ["token": token])
        #expect(stageCancelled["ok"] as? Bool == true)
        #expect(Self.failed(await Self.ask(model, "composer.copy.chunk", ["token": token, "offset": 0, "data": "YQ=="])))
        #expect(Self.failed(await Self.ask(model, "composer.copy.finish", ["token": token])))
        let fileCancelled = await Self.ask(model, "composer.copy.cancel", ["token": file.reference])
        #expect(fileCancelled["ok"] as? Bool == true)
        #expect(Self.failed(await Self.ask(model, "composer.copy.staged", ["text": text.reference, "items": [
            ["name": "one.txt", "mimeType": "text/plain", "reference": file.reference],
        ]])))
        #expect(effects.copied.isEmpty)
    }

    @Test func aNewerSmallCopyInvalidatesAnOlderStagedCopyAndItsLiveWrites() async throws {
        let (folder, model, effects) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let payloads = [Payload(name: "selection", size: 4, byte: 0x73), Payload(name: "one.txt", size: 4, byte: 0x61),
                        Payload(name: "live", size: 4, byte: 0x62)]
        let manifest = Self.manifest(payloads)
        model.transport.gestures.record()
        var batch: String?
        let text = try await Self.stage(model, payloads[0], index: 0, manifest: manifest, batch: &batch)
        let file = try await Self.stage(model, payloads[1], index: 1, manifest: manifest, batch: &batch)
        let live = try Self.value(await Self.ask(model, "composer.copy.begin", [
            "name": "copy-2", "size": 4, "batchToken": try #require(batch),
        ]))
        let token = try #require(live["token"] as? String)
        model.transport.gestures.record()
        _ = try Self.value(await Self.ask(model, "composer.copy", ["text": "newer copy", "items": [
            ["name": "new.txt", "mimeType": "text/plain", "text": "newer attachment"],
        ]]))
        #expect(Self.failed(await Self.ask(model, "composer.copy.chunk", ["token": token, "offset": 0, "data": "YQ=="])))
        #expect(Self.failed(await Self.ask(model, "composer.copy.finish", ["token": token])))
        #expect(Self.failed(await Self.ask(model, "composer.copy.staged", ["text": text.reference, "items": [
            ["name": "one.txt", "mimeType": "text/plain", "reference": file.reference],
        ]])))
        #expect(effects.copied.count == 1)
        #expect(effects.copied.first?.first?.string(forType: .string) == "newer copy")
    }

    @Test func aRemotePathNeverReadsTheSameSpellingOnThisMac() async throws {
        let (folder, model, effects) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.remoteChat = true
        let local = folder.appendingPathComponent("remote-name.txt")
        try Data("private local bytes".utf8).write(to: local)
        model.transport.gestures.record()
        var batch: String?
        let payload = Payload(name: "selection", size: 4, byte: 0x73)
        let text = try await Self.stage(model, payload, index: 0, manifest: Self.manifest([payload]), batch: &batch)
        #expect(Self.failed(await Self.ask(model, "composer.copy.staged", ["text": text.reference, "items": [
            ["name": "remote-name.txt", "mimeType": "text/plain", "path": local.path],
        ]])))
        #expect(effects.copied.isEmpty)
    }

    @Test func aPublishedCopyKeepsOnlyItsAttachmentFiles() async throws {
        let (folder, model, effects) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let params = try await Self.smallStagedCopy(model)
        #expect(Self.regularFiles(in: folder).count == 3)
        _ = try Self.value(await Self.ask(model, "composer.copy.staged", params))
        let item = try #require(effects.copied.first?.last)
        let file = try #require(item.string(forType: .fileURL).flatMap(URL.init(string:)))
        #expect(file.lastPathComponent == "one.txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == "aaaa")
        // The selection and ordering metadata cannot accumulate alongside published attachments.
        #expect(Self.regularFiles(in: folder) == Set([file.resolvingSymlinksInPath()]))
    }

    @Test func aFailedClipboardWriteRemovesAllOfItsStagedFiles() async throws {
        let (folder, model, effects) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let params = try await Self.smallStagedCopy(model)
        model.replyLinks.copyItems = { _ in false }
        #expect(Self.failed(await Self.ask(model, "composer.copy.staged", params)))
        #expect(Self.regularFiles(in: folder).isEmpty)
        #expect(Self.failed(await Self.ask(model, "composer.copy.staged", params)))
        #expect(effects.copied.isEmpty)
    }

    @Test func aCancelledNativeReplyNeverPublishesAndCleansItsStagedFiles() async throws {
        let (folder, model, effects) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let params = try await Self.smallStagedCopy(model)
        // A transport can cancel its reply independently of the page's token-cancel requests.
        let copying = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return Self.failed(await Self.ask(model, "composer.copy.staged", params))
        }
        #expect(await copying.value)
        #expect(effects.copied.isEmpty)
        #expect(Self.regularFiles(in: folder).isEmpty)
    }
}
