import Darwin
import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextComputerUse

/// The app's half of the helper's machine-consent questions: it answers
/// from its own daemon, whatever the question carries.
struct ComputerUseHelperConsentTests {
    @Test func aDaemonAnswerPassesThroughAndNoAnswerFailsClosed() throws {
        let granted = Data(#"{"consentRequired":true,"consent":{"screen":"granted","control":"none"},"lastRefusal":null}"#.utf8)
        let line = try #require(try JSONSerialization.jsonObject(with: ComputerUseHelperV2Consent.answer(id: 7, result: granted)) as? [String: Any])
        #expect(line["type"] as? String == "machine_consent")
        #expect(line["id"] as? Int == 7)
        #expect(line["ok"] as? Bool == true)
        let result = try #require(line["result"] as? [String: Any])
        #expect(result["consentRequired"] as? Bool == true)
        #expect(result["consent"] as? [String: String] == ["screen": "granted", "control": "none"])

        for failed in [nil, Data("not json".utf8), Data("[]".utf8)] as [Data?] {
            let line = try #require(try JSONSerialization.jsonObject(with: ComputerUseHelperV2Consent.answer(id: 8, result: failed)) as? [String: Any])
            #expect(line["ok"] as? Bool == false)
            #expect(line["result"] == nil)
        }
    }

    @Test(.timeLimit(.minutes(1))) func everyQuestionIsAskedOfTheDaemonAndNothingInItRedirects() async throws {
        let asked = Mutex(0)
        let refusals = Mutex<[String]>([])
        let (answers, continuation) = AsyncStream<Data>.makeStream()
        let send: @Sendable (Data) async -> Void = { continuation.yield($0) }
        let daemon: @Sendable () async -> Data? = {
            asked.withLock { $0 += 1 }
            return Data(#"{"consentRequired":true,"consent":{"screen":"none","control":"none"}}"#.utf8)
        }
        let refused: @Sendable (String) async -> Void = { surface in refusals.withLock { $0.append(surface) } }
        let question: [String: Any] = ["type": "machine_consent", "id": 3,
                                       "home": "/tmp/alternate", "socket": "/tmp/other.sock"]
        #expect(ComputerUseHelperV2Consent.handle(question, send: send, consent: daemon, refused: refused))
        #expect(ComputerUseHelperV2Consent.handle(["type": "machine_consent", "id": 4], send: send,
                                                  consent: daemon, refused: refused))
        var ids: Set<Int> = []
        for await answer in answers {
            let line = try #require(try JSONSerialization.jsonObject(with: answer) as? [String: Any])
            ids.insert(try #require(line["id"] as? Int))
            let result = try #require(line["result"] as? [String: Any])
            #expect(result["consent"] as? [String: String] == ["screen": "none", "control": "none"])
            if ids.count == 2 { break }
        }
        #expect(ids == [3, 4])
        #expect(asked.withLock { $0 } == 2, "no answer is cached")

        #expect(ComputerUseHelperV2Consent.handle(["type": "consent_refused", "surface": "control"], send: send,
                                                  consent: daemon, refused: refused))
        #expect(!ComputerUseHelperV2Consent.handle(["type": "ack", "of": "register_acpmux"], send: send,
                                                   consent: daemon, refused: refused))
    }

    /// The host link checks the server on its own connection: the helper
    /// pid this app started (here: this process listens), else no link.
    /// Its first line is the host secret, and it needs the helper's ok.
    @Test(.timeLimit(.minutes(1))) func theHostLinkConnectsOnlyToTheHelperItStarted() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cul-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "c.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(listener, 4) == 0)
        // The helper's end: the first connection that sends a line gets `{"ok":true}`.
        let (received, firstLine) = AsyncStream<String>.makeStream()
        Thread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var bytes = [UInt8](repeating: 0, count: 256)
                let count = read(client, &bytes, bytes.count)
                guard count > 0 else { close(client); continue }
                firstLine.yield(String(decoding: bytes.prefix(count), as: UTF8.self))
                _ = "{\"ok\":true}\n".utf8CString.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count - 1) }
                return
            }
        }.start()
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        let secret = Data(repeating: 0xA5, count: 32)
        let other = await ComputerUseHelperV2HostLink.connect(path: path, helperPID: getppid(), executable: executable,
                                                              secret: secret, team: nil)
        #expect(other == nil, "a socket another process serves is not the helper")
        let link = try #require(await ComputerUseHelperV2HostLink.connect(path: path, helperPID: getpid(),
                                                                          executable: executable, secret: secret, team: nil))
        var lines = received.makeAsyncIterator()
        #expect(await lines.next() == "{\"secret\":\"\(ComputerUseHelperV2.hex(secret))\"}\n")
        link.close()
        #expect(await link.send(Data("x\n".utf8)) == false, "closed")
        #expect(await ComputerUseHelperV2HostLink.connect(path: path + ".missing", helperPID: getpid(),
                                                          executable: executable, secret: secret, team: nil) == nil)
    }
}
