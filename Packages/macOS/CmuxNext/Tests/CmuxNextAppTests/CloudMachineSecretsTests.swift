@testable import CmuxNextCloud
import CryptoKit
import Foundation
import Testing

/// `cmux cloud deliver-secrets` (CloudMachineSecrets): which Keychain account answers each declared
/// name, the ledger that skips an unchanged machine, and the delivery itself, where a recording fake
/// of every channel proves a value only ever travels as input typed into the receiver's terminal on
/// the daemon link: never through exec, the file API, an argv or an error.
@Suite
struct CloudMachineSecretsTests {
    static let value = "postgres://u:s3cr3t-'\"$x@db/app"

    @Test func aRepoScopedValueWinsOverTheGlobalOneAndTheRestAreMissing() {
        let index: [String: Int64] = ["*/API_KEY": 1, "acme/app/API_KEY": 2, "*/DATABASE_URL": 3]
        let (items, missing) = CloudMachineSecrets.plan(declared: ["API_KEY", "DATABASE_URL", "SENTRY_DSN"], repo: "Acme/App", index: index)
        #expect(items.map(\.account) == ["acme/app/API_KEY", "*/DATABASE_URL"])
        #expect(items.map(\.setAtMs) == [2, 3])
        #expect(missing == ["SENTRY_DSN"])
        #expect(CloudMachineSecrets.plan(declared: ["API_KEY"], repo: nil, index: index).items.map(\.account) == ["*/API_KEY"],
                "without the person's --repo the machine gets only global values")
        let twice = CloudMachineSecrets.plan(declared: ["API_KEY", "API_KEY", "bad-name", "1X", "LC_ALL", "PYTHONPATH"], repo: nil,
                                             index: index.merging(["*/LC_ALL": 1, "*/PYTHONPATH": 1]) { a, _ in a })
        #expect(twice.items.map(\.name) == ["API_KEY"], "a repeated, malformed or reserved name is dropped, never a crash or a delivery")
        #expect(twice.missing.isEmpty)
    }

    @Test func onlyAOneLineValueOfEightCharactersTo16KiBIsDelivered() {
        #expect(CloudMachineSecrets.isValue("sk-live-123"))
        #expect(CloudMachineSecrets.isValue(String(repeating: "x", count: 16 * 1024)))
        for bad in ["", "1234567", "🔒🔑🔒🔑", "password\r\n", "xxxxxxxx\nPROMPT_COMMAND=id", "xxxxxxxx\ry", "xxxxxxxx\0y",
                    String(repeating: "x", count: 16 * 1024 + 1)] {
            #expect(!CloudMachineSecrets.isValue(bad))
        }
        // The most a machine config declares, each at the largest size, still fits one delivery.
        let most = (0..<100).map { (name: "SECRET_\($0)", value: String(repeating: "x", count: 16 * 1024)) }
        #expect(CloudMachineSecrets.payload(most, key: "k3y").count <= CloudMachineSecrets.maxPayloadBytes)
        #expect(CloudMachineSecrets.envFileBytes([("A", "it's")]) == "export A='it'\\''s'\n".utf8.count)
    }

    @Test func aSetWhoseFileWouldOutgrowTheAppliersLimitIsRefusedBeforeAnyTerminal() async {
        // Apostrophes grow fourfold in the file: 100 values of them fit the payload but not the file.
        let quotes = (0..<100).map { (name: "SECRET_\($0)", value: String(repeating: "'", count: 16 * 1024)) }
        #expect(CloudMachineSecrets.payload(quotes, key: "k3y").count <= CloudMachineSecrets.maxPayloadBytes)
        let recorder = Recorder()
        await #expect(throws: CloudMachineSecrets.DeliveryFailed(reason: "too-large")) {
            _ = try await CloudMachineSecrets.deliver(quotes, over: recorder.link, nonce: "n0nce", key: "k3y")
        }
        #expect(recorder.started.isEmpty && recorder.tickets.isEmpty)
    }

    @Test func theRepoScopeIsOwnerSlashName() {
        #expect(CloudMachineSecrets.repoScope("Acme/App") == "acme/app")
        #expect(CloudMachineSecrets.claimedRepo(record: Data(#"{"owner":"Acme","name":"App"}"#.utf8)) == "acme/app")
        #expect(CloudMachineSecrets.claimedRepo(record: Data(#"{"owner":"../x","name":"App"}"#.utf8)) == nil)
        #expect(CloudMachineSecrets.hasRepoValues(for: ["API_KEY"], repo: "acme/app", index: ["acme/app/API_KEY": 1]))
        #expect(!CloudMachineSecrets.hasRepoValues(for: ["API_KEY"], repo: "acme/app", index: ["*/API_KEY": 1]))
        for bad in ["acme", "acme/app/x", "../x", "acme/", "a b/c"] { #expect(CloudMachineSecrets.repoScope(bad) == nil, "\(bad)") }
    }

    @Test func theMachinesRecordsAndTheIndexParseAndNothingElseDoes() {
        #expect(CloudMachineSecrets.declared(status: Data(#"{"state":"done","secrets":{"declared":["A","B"],"missing":["B"]}}"#.utf8)) == ["A", "B"])
        #expect(CloudMachineSecrets.declared(status: Data(#"{"state":"done","secrets":{"declared":[]}}"#.utf8)) == [], "an explicit empty set")
        // Not "no secrets": a status that does not say, or an apply still running, delivers (and clears) nothing.
        #expect(CloudMachineSecrets.declared(status: Data("not json".utf8)) == nil)
        #expect(CloudMachineSecrets.declared(status: Data(#"{"state":"running"}"#.utf8)) == nil)
        #expect(CloudMachineSecrets.declared(status: nil) == nil)
        #expect(CloudMachineSecrets.index(from: .bytes(Data(#"{"version":1,"secrets":{"*/A":17}}"#.utf8))) == ["*/A": 17])
        #expect(CloudMachineSecrets.index(from: .missing) == [:], "no file: nothing was ever set")
        #expect(CloudMachineSecrets.index(from: .unreadable) == nil, "there (or maybe there) but unreadable: never empty")
        #expect(CloudMachineSecrets.index(from: .bytes(Data("{broken".utf8))) == nil)
        for bad in [#"{"secrets":{"*/A":true}}"#, #"{"secrets":{"*/A":1.5}}"#, #"{"secrets":{"*/A":-1}}"#, #"{"secrets":{"*/A":"v"}}"#,
                    #"{"secrets":{"A":1}}"#, #"{"secrets":{"Acme/App/A":1}}"#] {
            #expect(CloudMachineSecrets.index(from: .bytes(Data(bad.utf8))) == nil, "\(bad)")
        }
        #expect(CloudMachineSecrets.index(from: .bytes(Data(#"{"secrets":{"*/LC_ALL":1}}"#.utf8))) == nil, "a reserved name is not an account")
        #expect(CloudMachineSecrets.index(from: .bytes(Data(#"{"secrets":{"acme/app/A":2,"*/B":3}}"#.utf8))) == ["acme/app/A": 2, "*/B": 3])
    }

    @Test func aMachineThatHasWhatTheMacHoldsIsCurrentAndAChangeIsNot() {
        let items = CloudMachineSecrets.plan(declared: ["A"], repo: nil, index: ["*/A": 1]).items
        var ledger = CloudMachineSecrets.Ledger()
        #expect(!ledger.isCurrent(items, on: "vm-1"))
        ledger.record(items, on: "vm-1")
        #expect(ledger.isCurrent(items, on: "vm-1"))
        #expect(!ledger.isCurrent(CloudMachineSecrets.plan(declared: ["A"], repo: nil, index: ["*/A": 2]).items, on: "vm-1"), "set again: deliver again")
        #expect(!ledger.isCurrent(items, on: "vm-2"))
        #expect(!ledger.isCurrent([], on: "vm-3"), "an empty set is delivered once to a machine with no record")
        ledger.record([], on: "vm-3")
        #expect(ledger.isCurrent([], on: "vm-3"))
    }

    @Test func twoMachinesRecordedThroughTheFileKeepBoth() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(atPath: url.path + ".lock") }
        let items = CloudMachineSecrets.plan(declared: ["A"], repo: nil, index: ["*/A": 1]).items
        try CloudMachineSecrets.Ledger.record(items, on: "vm-1", at: url)
        try CloudMachineSecrets.Ledger.record([], on: "vm-2", at: url)
        let ledger = try JSONDecoder().decode(CloudMachineSecrets.Ledger.self, from: Data(contentsOf: url))
        #expect(ledger.isCurrent(items, on: "vm-1") && ledger.isCurrent([], on: "vm-2"))
    }

    @Test func onlyAnIndexThatIsNotThereReadsAsNoSecrets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cloud-secrets.json")
        #expect(CloudMachineSecrets.read(file.path) == .missing)
        try Data("{}".utf8).write(to: file)
        #expect(CloudMachineSecrets.read(file.path) == .bytes(Data("{}".utf8)))
        #expect(CloudMachineSecrets.read(file.path, max: 1) == .unreadable, "never read past its bound")
        // A path that cannot be looked at (here through a file, ENOTDIR; EACCES alike) is not "missing".
        #expect(CloudMachineSecrets.read(file.path + "/cloud-secrets.json") == .unreadable)
        // A FIFO is never waited on (nobody writes it: a blocking open would hang).
        let fifo = folder.appendingPathComponent("fifo").path
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(CloudMachineSecrets.read(fifo) == .unreadable)
        let link = folder.appendingPathComponent("link").path
        #expect(symlink(file.path, link) == 0)
        #expect(CloudMachineSecrets.read(link) == .unreadable, "never through a link")
    }

    /// Every channel a delivery could use, recorded.
    nonisolated final class Recorder: @unchecked Sendable {
        var tickets: [Data] = []
        var started: [[String]] = []
        var typed: [Data] = []
        var waited: [String] = []
        var closed: [String] = []
        var answers: [String] = ["CMUX-SECRETS-READY n0nce\n", "CMUX-SECRETS-OK 1 \(CloudMachineSecrets.okToken(key: "k3y", count: 1))\n"]

        var link: CloudMachineSecrets.Link {
            CloudMachineSecrets.Link(
                writeTicket: { self.tickets.append($0) },
                start: { self.started.append($0); return "7 term-1" },
                waitFor: { _, pattern, _ in self.waited.append(pattern); return self.answers.removeFirst() },
                type: { _, bytes in self.typed.append(bytes) },
                close: { self.closed.append($0) })
        }
    }

    @Test func aValueOnlyEverTravelsAsTypedInputAfterTheReceiverTurnedEchoOff() async throws {
        let recorder = Recorder()
        let written = try await CloudMachineSecrets.deliver([("DATABASE_URL", Self.value)], over: recorder.link, nonce: "n0nce", key: "k3y")
        #expect(written == 1)
        #expect(recorder.started == [["sh", CloudMachineSecrets.receiverPath, CloudMachineSecrets.ticketPath]],
                "argv names the receiver and its ticket, never a value, the nonce or the key")
        #expect(recorder.tickets == [Data("n0nce\nk3y\nDATABASE_URL\n".utf8)],
                "the ticket (file API) carries the nonce, the payload key and the names, never a value")
        #expect(recorder.waited.first == "CMUX-SECRETS-READY n0nce|CMUX-SECRETS-ERR [a-z-]+", "nothing is typed before the receiver says echo is off")
        #expect(recorder.typed.count == 1)
        let typed = String(decoding: recorder.typed[0], as: UTF8.self)
        #expect(!typed.contains("s3cr3t"), "the typed bytes are base64, so no shell or terminal reads the value")
        #expect(typed.hasSuffix("\nCMUX-SECRETS-END k3y\n"), "the end marker carries the key, which no screen ever showed")
        #expect("CMUX-SECRETS-OK 1 \(CloudMachineSecrets.okToken(key: "k3y", count: 1))".count <= 60, "the answer never wraps in a narrow terminal")
        let lines = typed.split(separator: "\n").map(String.init)
        let body = lines.prefix { !$0.hasPrefix(CloudMachineSecrets.mac) }.map { $0 + "\n" }.joined()
        let digest = SHA256.hash(data: Data(("k3y\n" + body).utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(lines.contains("\(CloudMachineSecrets.mac) \(digest)"), "the MAC covers exactly the base64 lines, keyed")
        let decoded = Data(base64Encoded: body, options: .ignoreUnknownCharacters)
        #expect(decoded.map { String(decoding: $0, as: UTF8.self) } == "DATABASE_URL=\(Self.value)\n")
        #expect(recorder.closed == ["7 term-1"])
        #expect(!CloudMachineSecrets.receiver.contains("s3cr3t"), "the receiver, uploaded with the file API, holds no value")
    }

    @Test func aRefusalClosesTheTerminalAndCarriesOnlyAKnownCode() async {
        let recorder = Recorder()
        recorder.answers = ["CMUX-SECRETS-READY n0nce\n", "CMUX-SECRETS-ERR bad-name\n"]
        await #expect(throws: CloudMachineSecrets.DeliveryFailed(reason: "bad-name")) {
            _ = try await CloudMachineSecrets.deliver([("API_KEY", Self.value)], over: recorder.link, nonce: "n0nce", key: "k3y")
        }
        #expect(recorder.closed == ["7 term-1"])
        // A machine that answers with anything else (a value it decoded) is reported as `unexpected`.
        let echoing = Recorder()
        echoing.answers = ["CMUX-SECRETS-READY n0nce\n", "CMUX-SECRETS-ERR \(Self.value)\n"]
        await #expect(throws: CloudMachineSecrets.DeliveryFailed(reason: "unexpected")) {
            _ = try await CloudMachineSecrets.deliver([("API_KEY", Self.value)], over: echoing.link, nonce: "n0nce", key: "k3y")
        }
        // A go-ahead followed by an error (the receiver already gave up) gets nothing typed.
        let gaveUp = Recorder()
        gaveUp.answers = ["CMUX-SECRETS-READY n0nce\nCMUX-SECRETS-ERR eof\n"]
        await #expect(throws: CloudMachineSecrets.DeliveryFailed(reason: "eof")) {
            _ = try await CloudMachineSecrets.deliver([("API_KEY", Self.value)], over: gaveUp.link, nonce: "n0nce")
        }
        #expect(gaveUp.typed.isEmpty)
        // A set over the receiver's limit is refused before a terminal opens.
        let big = Recorder()
        let huge = String(repeating: "x", count: CloudMachineSecrets.maxPayloadBytes)
        await #expect(throws: CloudMachineSecrets.DeliveryFailed(reason: "too-large")) {
            _ = try await CloudMachineSecrets.deliver([("API_KEY", huge)], over: big.link, nonce: "n0nce")
        }
        #expect(big.started.isEmpty && big.tickets.isEmpty)
        // A go-ahead without this delivery's nonce (another client typed it) gets nothing typed.
        let forged = Recorder()
        forged.answers = ["CMUX-SECRETS-READY\n"]
        await #expect(throws: CloudMachineSecrets.DeliveryFailed.self) {
            _ = try await CloudMachineSecrets.deliver([("API_KEY", Self.value)], over: forged.link, nonce: "n0nce")
        }
        #expect(forged.typed.isEmpty)
        // An OK without the token (another client typed it before echo went off) is a failure.
        let forgedOK = Recorder()
        forgedOK.answers = ["CMUX-SECRETS-OK 1\nCMUX-SECRETS-READY n0nce\n", "CMUX-SECRETS-OK 1\nCMUX-SECRETS-READY n0nce\n"]
        await #expect(throws: CloudMachineSecrets.DeliveryFailed.self) {
            _ = try await CloudMachineSecrets.deliver([("API_KEY", Self.value)], over: forgedOK.link, nonce: "n0nce", key: "k3y")
        }
        #expect(forgedOK.waited.last?.contains(CloudMachineSecrets.okToken(key: "k3y", count: 1)) == true, "the wait asks for the token")
        let noTTY = Recorder()
        noTTY.answers = ["CMUX-SECRETS-ERR no-tty\n"]
        await #expect(throws: CloudMachineSecrets.DeliveryFailed(reason: "no-tty")) {
            _ = try await CloudMachineSecrets.deliver([("API_KEY", Self.value)], over: noTTY.link, nonce: "n0nce")
        }
        #expect(noTTY.typed.isEmpty, "a receiver that could not turn echo off gets nothing typed")
        #expect(noTTY.closed == ["7 term-1"])
    }
}
