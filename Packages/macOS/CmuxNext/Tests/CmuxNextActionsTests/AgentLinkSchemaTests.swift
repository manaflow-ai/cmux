@testable import CmuxNextActions
import Foundation
import Testing

/// `schemas/deeplinks/agent-link.json` is the one schema for agent session links: the parameters,
/// their charsets, what happens to one cmux cannot use, and the vectors. cmux.com's deeplink page
/// writes links by it (`web/tests/deeplink-agent.test.ts` runs the same vectors), this app parses
/// by it, and these tests hold the parser to it, so an emitter and a parser cannot drift.
///
/// The rules the vectors hold: the harness and the session id say which chat a link is, so a link
/// missing either, or with one outside its charset, is not a link; `host`, `name`, `message` and
/// `machine` are hints, so a repeated one or one cmux cannot read is named and dropped, never
/// costing the session; and a link cmux.com builds carries nothing cmux ignores.
struct AgentLinkSchemaTests {
    struct Vector: Sendable {
        let name: String
        /// The query of the cmux.com link, when the vector has one.
        let web: String?
        /// The native link, nil when the page builds none.
        let link: String?
        /// The fields the link names, nil when it is not a link at all.
        let fields: [String: String]?
        /// What was ignored: in `web` for a vector that has one, else in `link`.
        let ignored: [String]
    }

    /// The schema, read fresh (JSON objects are not `Sendable`).
    nonisolated static func schema() -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let url = root.appending(path: "schemas/deeplinks/agent-link.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    nonisolated static let vectors: [Vector] = (schema()["vectors"] as? [[String: Any]] ?? []).compactMap { row in
        guard let name = row["name"] as? String else { return nil }
        return Vector(name: name, web: row["web"] as? String, link: row["link"] as? String,
                      fields: row["fields"] as? [String: String], ignored: row["ignored"] as? [String] ?? [])
    }

    static func fields(of link: DeepLink) -> [String: String]? {
        guard case .agent(let harness, let session) = link.target else { return nil }
        var fields = ["harness": harness, "session": session]
        if let machine = link.machine { fields["machine"] = machine }
        if let host = link.hostHint { fields["host"] = host }
        if let name = link.nameHint { fields["name"] = name }
        if let message = link.message { fields["message"] = message }
        return fields
    }

    /// The schema is in the repository and describes this kind of link.
    @Test func theSchemaIsThere() {
        #expect(Self.schema()["nativeHost"] as? String == "agent")
        #expect(Self.schema()["pathParams"] as? [String] == ["harness", "session"])
        #expect(Self.schema()["queryParams"] as? [String] == ["host", "name", "message", "machine"])
        #expect(Self.vectors.count >= 20)
        #expect(Self.vectors.filter { $0.link != nil }.count >= 15)
    }

    /// The parameters the parser reads are the schema's.
    @Test func theParserReadsTheSchemasParameters() {
        let queries = Self.schema()["queryParams"] as? [String] ?? []
        #expect(!queries.isEmpty)
        #expect(DeepLink.parameters(of: .agent(harness: "claude", session: "s1")) == Set(queries))
    }

    /// Every charset the schema states is the one this app reads, probe for probe: the web page
    /// compares its own expressions to these strings, so a bound that moves on one side without the
    /// other fails here (a 65-character harness, a 257-character session, a
    /// 201-character message, an empty value, `..`).
    @Test func theParsersCharsetsAreTheSchemas() throws {
        let params = try #require(Self.schema()["params"] as? [String: [String: Any]], "the schema states its parameters")
        let readers: [String: (String) -> Bool] = [
            "harness": DeepLink.isHarness,
            "session": DeepLink.isAgentSession,
            "host": DeepLink.isHint,
            "name": DeepLink.isHint,
            "message": DeepLink.isAgentMessage,
            "machine": { DeepLink.isResourceID($0, prefix: "machine_") },
        ]
        let probes = ["a", "A", "claude-code", "Claude", "ses-01.example_a", "msg_01hq9f4c7k",
                      "5cf944c9-b816-486a-a3aa-c89b3faea35f", "machine_0123456789abcdef0123456789abcdef",
                      "machine_0123456789ABCDEF0123456789abcdef", "machine_0123456789abcdef", "",
                      ".", "..", "...", "a b", "a/b", "a?b", "a%20b", "<script>", "a@b", "a:b",
                      String(repeating: "a", count: 64), String(repeating: "a", count: 65),
                      "session:with:colon", String(repeating: "a", count: 200), String(repeating: "a", count: 201),
                      String(repeating: "a", count: 256), String(repeating: "a", count: 257)]
        #expect(Set(params.keys) == Set(readers.keys))
        for (name, spec) in params {
            let pattern = try #require(spec["pattern"] as? String, "\(name) states a charset")
            let regex = try NSRegularExpression(pattern: pattern)
            let reads = try #require(readers[name], "\(name) has a reader here")
            for probe in probes {
                let whole = NSRange(location: 0, length: (probe as NSString).length)
                let fits = regex.firstMatch(in: probe, options: [], range: whole) != nil
                #expect(reads(probe) == fits, "\(name) reads \(probe.count) characters differently from the schema")
            }
        }
    }

    /// Every vector's native link parses to the fields the schema states, or to nothing when the
    /// schema says it is not a link.
    @Test(arguments: Self.vectors) func theParserMatchesTheSchema(_ vector: Vector) throws {
        guard let text = vector.link else { return }
        let url = try #require(URL(string: text), "\(vector.name): \(text) is a URL")
        guard let fields = vector.fields else {
            #expect(DeepLink.read(url, scheme: "cmux") == nil, "\(vector.name): \(text) is not a link")
            return
        }
        let parsed = try #require(DeepLink.read(url, scheme: "cmux"), "\(vector.name): \(text) is a link")
        #expect(Self.fields(of: parsed.link) == fields, "\(vector.name)")
        // A link cmux.com builds carries only what it kept, so cmux ignores nothing in it; a
        // vector that is only a native link states what cmux ignored in it.
        #expect(parsed.ignoredParameters == (vector.web == nil ? vector.ignored : []), "\(vector.name)")
    }

    /// What the parser read is written back as the same link, so the emitter and the parser are
    /// one grammar. A native-only vector carried parameters cmux ignores, so its link is written
    /// back without them, and still names the same chat.
    @Test(arguments: Self.vectors) func everyLinkIsWrittenBackAsItself(_ vector: Vector) throws {
        guard let text = vector.link, vector.fields != nil,
              let parsed = DeepLink.read(try #require(URL(string: text)), scheme: "cmux") else { return }
        let written = try #require(parsed.link.url(scheme: "cmux"), "\(vector.name) is written back")
        if vector.web != nil { #expect(written.absoluteString == text, "\(vector.name)") }
        #expect(DeepLink.parse(written, scheme: "cmux") == parsed.link, "\(vector.name) round trips")
    }

    /// The link Leo opened: the message and the host come through.
    @Test func aMessageLinkNamesTheMessage() throws {
        let url = try #require(URL(string: "cmux://agent/claude/e8f63fd9-94e8-4878-bcd4-704659aba1f2"
            + "?host=cosmic-gray&message=5cf944c9-b816-486a-a3aa-c89b3faea35f"))
        let link = try #require(DeepLink.parse(url, scheme: "cmux"))
        #expect(link.target == .agent(harness: "claude", session: "e8f63fd9-94e8-4878-bcd4-704659aba1f2"))
        #expect(link.hostHint == "cosmic-gray")
        #expect(link.message == "5cf944c9-b816-486a-a3aa-c89b3faea35f")
        #expect(link.nameHint == nil)
        #expect(link.url(scheme: "cmux") == url)
    }

    /// A message that is not a token, a repeated one, and one that is only dots: dropped by name,
    /// and the session still opens.
    @Test(arguments: [
        "cmux://agent/claude/s1?message=m%201",
        "cmux://agent/claude/s1?message=",
        "cmux://agent/claude/s1?message=..",
        "cmux://agent/claude/s1?message=" + String(repeating: "m", count: 201),
        "cmux://agent/claude/s1?message=m-1&message=m-2",
    ]) func anUnusableMessageIsDroppedNotTheLink(_ text: String) throws {
        let url = try #require(URL(string: text))
        let parsed = try #require(DeepLink.read(url, scheme: "cmux"))
        #expect(parsed.link.target == .agent(harness: "claude", session: "s1"))
        #expect(parsed.link.message == nil)
        #expect(parsed.ignoredParameters == ["message"], "\(text)")
    }

    /// A parameter no agent link reads, and a `machine` it cannot read: named, and the session
    /// still opens. One stray parameter never costs a chat (the bug cmux.com had).
    @Test(arguments: [
        ("cmux://agent/claude/s1?cwd=%2Fhome%2Fleo", ["cwd"]),
        ("cmux://agent/claude/s1?cwd=x&cwd=y", ["cwd"]),
        ("cmux://agent/claude/s1?machine=not-a-resource-id", ["machine"]),
        // The page cannot tell `?machine` from `?machine=`, so neither reader does.
        ("cmux://agent/claude/s1?machine", ["machine"]),
        ("cmux://agent/claude/s1?machine=", ["machine"]),
        ("cmux://agent/claude/s1?machine=machine_0123456789abcdef0123456789abcdef"
            + "&machine=machine_fedcba9876543210fedcba9876543210", ["machine"]),
        ("cmux://agent/claude/s1?host=a&host=b", ["host"]),
        ("cmux://agent/claude/s1?account=someone%40example.com", ["account"]),
        // `machine` comes before the hints, which come before a name no agent link reads, in the
        // order `params` lists them (agent-link.json `ignoredOrder`), whatever the URL's order.
        ("cmux://agent/claude/s1?cwd=x&host=a&host=b&machine=nope", ["machine", "host", "cwd"]),
        ("cmux://agent/claude/s1?message=&name=a&name=b", ["name", "message"]),
    ]) func aStrayParameterNeverCostsTheChat(_ text: String, _ ignored: [String]) throws {
        let url = try #require(URL(string: text))
        let parsed = try #require(DeepLink.read(url, scheme: "cmux"))
        #expect(parsed.link.target == .agent(harness: "claude", session: "s1"))
        #expect(parsed.ignoredParameters == ignored, "\(text)")
    }

    /// What a reader may never say a link ignored: an agent link's path carries its harness and
    /// its session where the page carries them as parameters, so `?session=x` beside
    /// `cmux://agent/claude/s1` is ignored, yet never named -- naming it would deny the chat the
    /// link just opened (schemas/deeplinks/agent-link.json `pathParams`, `ignoredOrder`).
    @Test func theNamesOfAnAgentLinksPathAreNeverSaidToBeIgnored() throws {
        let url = try #require(URL(string: "cmux://agent/claude/s1?session=x&harness=y&cwd=z"))
        let parsed = try #require(DeepLink.read(url, scheme: "cmux"))
        #expect(parsed.link.target == .agent(harness: "claude", session: "s1"))
        #expect(parsed.ignoredParameters == ["session", "harness", "cwd"])
        let used = parsed.link.usedParameters
        #expect(used.isSuperset(of: ["harness", "session"]), "\(used)")
        #expect(!used.contains("cwd"), "\(used)")
        // Only an agent link's path names them: another kind's `?session=x` is a stray name.
        let tab = try #require(URL(string: "cmux://tab/tab_0123456789abcdef0123456789abcdef?session=x"))
        let other = try #require(DeepLink.read(tab, scheme: "cmux"))
        #expect(other.ignoredParameters == ["session"])
        #expect(other.link.usedParameters.isEmpty, "\(other.link.usedParameters)")
    }

    /// A link with every parameter right ignores nothing.
    @Test func aLinkWithNothingStrayIgnoresNothing() throws {
        let url = try #require(URL(string: "cmux://agent/codex/s1?host=big-red&name=Rivetmoss&message=msg_1"
            + "&machine=machine_0123456789abcdef0123456789abcdef"))
        #expect(DeepLink.read(url, scheme: "cmux")?.ignoredParameters == [])
    }

    /// The other kinds are read as they always were: their stray parameters are ignored by name,
    /// and a `machine` they cannot read is still a refusal, not a hint to drop.
    @Test func theOtherKindsAreUnchanged() throws {
        let tab = "tab_0123456789abcdef0123456789abcdef"
        let stray = try #require(URL(string: "cmux://tab/\(tab)?cwd=x"))
        let parsed = try #require(DeepLink.read(stray, scheme: "cmux"))
        #expect(parsed.link == DeepLink(.tab(tab)))
        #expect(parsed.ignoredParameters == ["cwd"])
        let badMachine = try #require(URL(string: "cmux://session/ses-01?machine=nope"))
        #expect(DeepLink.read(badMachine, scheme: "cmux") == nil)
        // `?machine` with no value names no machine, as it always did: it is not a machine cmux
        // cannot read, so the link still opens.
        let noMachine = try #require(URL(string: "cmux://tab/\(tab)?machine"))
        let valueless = try #require(DeepLink.read(noMachine, scheme: "cmux"))
        #expect(valueless.link == DeepLink(.tab(tab)))
        // Two machines on another kind read as the first one did before.
        let machine = "machine_0123456789abcdef0123456789abcdef"
        let repeated = try #require(URL(string: "cmux://tab/\(tab)?machine=\(machine)&machine=machine_ffff"))
        #expect(DeepLink.read(repeated, scheme: "cmux")?.link == DeepLink(.tab(tab), machine: machine))
        let workspace = "6B1F0A52-6C0F-4B44-9A43-0F4C2C0E6D11"
        let legacy = try #require(URL(string: "cmux://workspace/\(workspace)?stable_workspace_id=\(workspace)"))
        #expect(DeepLink.read(legacy, scheme: "cmux")?.ignoredParameters == [])
    }

    /// A message rides only on an agent link: on any other it would not parse back.
    @Test func aMessageNeverRidesOnAnotherLink() throws {
        let tab = "tab_0123456789abcdef0123456789abcdef"
        #expect(DeepLink(.tab(tab), message: "msg_1").url(scheme: "cmux") == nil)
        let url = try #require(URL(string: "cmux://tab/\(tab)?message=msg_1"))
        let link = try #require(DeepLink.parse(url, scheme: "cmux"))
        #expect(link.message == nil)
        #expect(link.url(scheme: "cmux")?.absoluteString == "cmux://tab/\(tab)")
    }

    /// A link is written only for values that fit the schema, so a formatted link always parses
    /// back to the same chat.
    @Test func onlyWellFormedMessagesAreWritten() {
        func written(_ message: String) -> URL? {
            DeepLink(.agent(harness: "claude", session: "s1"), message: message).url(scheme: "cmux")
        }
        #expect(written("msg_01") != nil)
        #expect(written(String(repeating: "m", count: 200)) != nil)
        #expect(written(String(repeating: "m", count: 201)) == nil)
        #expect(written("") == nil)
        #expect(written("..") == nil)
        #expect(written("msg 1") == nil)
        #expect(written("msg/1") == nil)
    }
}
