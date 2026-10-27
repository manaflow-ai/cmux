import CmuxFuzzSupport
@testable import CmuxNextUpdater
import CryptoKit
import Foundation
import Testing

/// Seeded fuzz of what the update feeds send (plans/cmux-next/chrome-parity/p10-stability.md, task 180): the
/// Sparkle appcast, the signed web update pointer and its key file, What's New documents, release notes, the
/// announcements feed, the pulled-build list, and the small JSON the updater reads from the CLI. Garbage,
/// truncated and deeply nested input (`hostileAppcastsAreBounded` for XML, `deepJSONNestingIsRefusedOrDecoded`
/// for JSON: up to 2,000 levels in each walked field). Chrome fuzzes its update client's parsers the same way
/// (components/update_client/protocol_parser_json_fuzzer.cc) and checks the signature before it reads a
/// field (components/update_client/update_checker.cc, CUP).
///
/// The properties:
/// - no input traps; a decoder returns a value or refuses with its own error;
/// - the appcast reader never resolves an external entity, and its pick is an item this Mac can run that is
///   newer than the running build;
/// - a web update pointer is taken only with its signature: a damaged envelope gives the signed pointer or a
///   refusal, never another pointer, and a signed payload is taken only when every field is well formed;
/// - a What's New document keeps only entries for this Mac with safe media, https docs and `cmux://` links;
/// - versions read back from their own text.
///
/// It runs only with `CMUX_UPDATER_FUZZ=1`; agents run it on the fleet, CI does not (Lawrence 2026-10-23):
///
/// ```
/// CMUX_UPDATER_FUZZ=1 swift test --filter AppcastFuzzTests
/// CMUX_UPDATER_FUZZ=1 CMUX_FUZZ_DEADLINE=$(( $(date +%s) + 300 )) swift test --filter AppcastFuzzTests
/// ```
///
/// The runs are CmuxFuzzSupport `FuzzRun`s (p10-stability-016): `CMUX_FUZZ_SEED` and `CMUX_FUZZ_ITERATIONS`
/// replay a failure, and with `CMUX_FUZZ_ARTIFACTS` set a trap leaves its input behind.
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_UPDATER_FUZZ"] == "1",
        "set CMUX_UPDATER_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
struct AppcastFuzzTests {
    /// Two minutes past a long run's budget, so the limit stops a hang and never a long run.
    nonisolated static let timeLimitMinutes: Int = {
        let budget = (try? FuzzEnvironment.current())?.longModeBudget(from: Date()) ?? 0
        return 2 + Int((budget / 60).rounded(.up))
    }()

    /// One input of the byte properties, its choices read from `data` (the libFuzzer entry, p10-stability-182).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        let branch = rng.below(4)
        let bytes = rng.bytes(4_096)
        switch branch {
        case 0: try AppcastFuzzCases.appcast(bytes)
        case 1: try AppcastFuzzCases.whatsNew(bytes)
        case 2: try AppcastFuzzCases.envelope(bytes, signer: try AppcastFuzzCases.Signer())
        default: try AppcastFuzzCases.feedJSON(bytes)
        }
    }

    @Test(.timeLimit(.minutes(AppcastFuzzTests.timeLimitMinutes)))
    func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("Appcast.oneInput", seed: 0xA9C0_0180_0001, iterations: 2_000)
        let tapes: [[UInt8]] = [[0], [1], [2], [3], [0, 30, 60, 99, 104, 97, 110, 110, 101, 108, 62]]
        try run.forEachInput(try run.corpus(seeds: tapes.map { Data($0) })) { try Self.oneInput($0) }
    }

    /// Appcasts damaged by byte and XML-token edits: items or `AppcastParseError`, and a pick that holds.
    @Test(.timeLimit(.minutes(AppcastFuzzTests.timeLimitMinutes)))
    func appcastsParseOrAreRefused() throws {
        let run = try FuzzRun("Appcast.xml", seed: 0xA9C0_0180_0002, iterations: 6_000)
        let mutator = FuzzMutator(dictionary: AppcastFuzzCases.xmlTokens, maximumEdits: 6, maximumCount: 1 << 14)
        try run.forEachInput(try run.corpus(seeds: AppcastFuzzCases.appcastSeeds), mutator: mutator) {
            try AppcastFuzzCases.appcast($0)
        }
    }

    /// The XML a hostile feed could send: deep nesting, entity expansion and external entities.
    @Test(.timeLimit(.minutes(AppcastFuzzTests.timeLimitMinutes)), arguments: AppcastFuzzCases.hostileAppcasts)
    func hostileAppcastsAreBounded(xml: String) throws {
        try AppcastFuzzCases.appcast(Data(xml.utf8))
    }

    /// `sparkle:minimumSystemVersion`, What's New versions and commit subjects read back from their text.
    @Test(.timeLimit(.minutes(AppcastFuzzTests.timeLimitMinutes)))
    func versionsReadBackFromTheirText() throws {
        try FuzzRun("Appcast.versions", seed: 0xA9C0_0180_0003, iterations: 20_000).forEach { rng in
            try AppcastFuzzCases.versions(&rng)
        }
    }

    /// What's New documents with JSON-token edits keep only what this Mac may show.
    @Test(.timeLimit(.minutes(AppcastFuzzTests.timeLimitMinutes)))
    func whatsNewDocumentsKeepOnlySafeEntries() throws {
        let run = try FuzzRun("Appcast.whatsNew", seed: 0xA9C0_0180_0004, iterations: 6_000)
        let mutator = FuzzMutator(dictionary: AppcastFuzzCases.jsonTokens, maximumEdits: 6, maximumCount: 1 << 14)
        try run.forEachInput(try run.corpus(seeds: [AppcastFuzzCases.whatsNewSeed]), mutator: mutator) {
            try AppcastFuzzCases.whatsNew($0)
        }
    }

    /// A signed pointer envelope damaged anywhere gives the signed pointer or a refusal, never another pointer.
    @Test(.timeLimit(.minutes(AppcastFuzzTests.timeLimitMinutes)))
    func damagedPointerEnvelopesNeverGiveAnotherPointer() throws {
        let signer = try AppcastFuzzCases.Signer()
        let run = try FuzzRun("Appcast.envelope", seed: 0xA9C0_0180_0005, iterations: 6_000)
        let mutator = FuzzMutator(dictionary: AppcastFuzzCases.jsonTokens, maximumEdits: 4, maximumCount: 1 << 13)
        let genuine = try signer.envelope(AppcastFuzzCases.pointerFields())
        try run.forEachInput(try run.corpus(seeds: [genuine]), mutator: mutator) { try AppcastFuzzCases.envelope($0, signer: signer) }
    }

    /// Payloads signed by the trusted key, each field right, wrong or missing: taken only when all are well formed.
    @Test(.timeLimit(.minutes(AppcastFuzzTests.timeLimitMinutes)))
    func signedPayloadsAreTakenOnlyWhenWellFormed() throws {
        let signer = try AppcastFuzzCases.Signer()
        try FuzzRun("Appcast.payload", seed: 0xA9C0_0180_0006, iterations: 4_000).forEach { rng in
            try AppcastFuzzCases.signedPayload(&rng, signer: signer)
        }
    }

    /// Nesting at and past the JSON parsers' bound in every field the JSON decoders walk (What's New entries and
    /// media, release notes, announcements, the pulled list, keys, a pointer envelope and a signed payload):
    /// refused or decoded by each property, never a stack overflow or a trap.
    @Test(.timeLimit(.minutes(AppcastFuzzTests.timeLimitMinutes)), arguments: [1, 64, 255, 256, 511, 512, 513, 2_000])
    func deepJSONNestingIsRefusedOrDecoded(depth: Int) throws {
        let signer = try AppcastFuzzCases.Signer()
        for data in AppcastFuzzCases.deepDocuments(depth: depth) {
            try AppcastFuzzCases.whatsNew(data)
            try AppcastFuzzCases.feedJSON(data)
            try AppcastFuzzCases.envelope(data, signer: signer)
        }
        for payload in AppcastFuzzCases.deepPayloads(depth: depth) {
            let pointer = signer.pointer(try signer.envelope(bytes: payload))
            try FuzzRun.check(pointer == nil, "a signed payload nested \(depth) deep was taken: \(String(describing: pointer))")
        }
    }

    /// Release notes, the index, announcements, the pulled list, web update state and keys, and the CLI's JSON,
    /// damaged by JSON-token edits.
    @Test(.timeLimit(.minutes(AppcastFuzzTests.timeLimitMinutes)))
    func feedJSONDecodesOrIsRefused() throws {
        let run = try FuzzRun("Appcast.feedJSON", seed: 0xA9C0_0180_0007, iterations: 6_000)
        let mutator = FuzzMutator(dictionary: AppcastFuzzCases.jsonTokens, maximumEdits: 6, maximumCount: 1 << 14)
        try run.forEachInput(try run.corpus(seeds: AppcastFuzzCases.feedSeeds), mutator: mutator) {
            try AppcastFuzzCases.feedJSON($0)
        }
    }
}

/// The inputs and properties of ``AppcastFuzzTests``.
@MainActor
enum AppcastFuzzCases {
    // MARK: Inputs

    static let xmlTokens: [Data] = [
        "<rss>", "</rss>", "<channel>", "</channel>", "<item>", "</item>", "<sparkle:deltas>", "</sparkle:deltas>",
        "<sparkle:version>", "</sparkle:version>", "<sparkle:minimumSystemVersion>", "</sparkle:minimumSystemVersion>",
        "<enclosure url=\"https://files.cmux.com/a.zip\" sparkle:version=\"9\"/>", "<![CDATA[", "]]>", "&amp;", "&#0;",
        "&#x10FFFF;", "&lt;", "<!--", "-->", "<?xml version=\"1.0\"?>", "<!DOCTYPE r [<!ENTITY a \"aaaa\">]>", "&a;",
        "\"", "'", "=", "/>", "26.0", "15.6.1", "99999999999999999999", "-1", "\u{0}", "\u{FEFF}",
    ].map { Data($0.utf8) }

    static let jsonTokens: [Data] = FuzzJSON.tokens + [
        #""schemaVersion""#, #""version""#, #""entries""#, #""platforms""#, #""macos""#, #""media""#, #""docs""#,
        #""tryIt""#, #""deeplink""#, #""schema""#, #""payload""#, #""signatures""#, #""key_id""#, #""sig""#,
        #""build""#, #""changes""#, #""items""#, #""keys""#, #""ed25519""#, #""addresses""#, "\"media/../x\"",
        "\"cmux://x\"", "\"https://cmux.com\"", "\"1.2.3-rc.4\"",
    ].map { Data($0.utf8) }

    static let appcastXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
    <title>cmux NEXT</title>
    <item>
    <title>cmux NEXT 1.2.3</title>
    <pubDate>Sat, 10 Oct 2026 03:05:21 +0000</pubDate>
    <sparkle:version>2026101001</sparkle:version>
    <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <sparkle:channel>nightly-next</sparkle:channel>
    <sparkle:releaseNotesLink>https://cmux.com/notes</sparkle:releaseNotesLink>
    <description><![CDATA[New: a thing]]></description>
    <enclosure url="https://files.cmux.com/cmux.zip" sparkle:version="2026101001" length="123" type="application/octet-stream"/>
    <sparkle:deltas><enclosure url="https://files.cmux.com/d.delta" sparkle:deltaFrom="2026100901"/></sparkle:deltas>
    </item>
    <item>
    <title>cmux NEXT 1.2.4</title>
    <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
    <sparkle:maximumSystemVersion>27.1.2</sparkle:maximumSystemVersion>
    <enclosure url="https://files.cmux.com/cmux2.zip" sparkle:version="2026101101" sparkle:shortVersionString="1.2.4"/>
    </item>
    </channel>
    </rss>
    """

    static let appcastSeeds: [Data] = [appcastXML, "<rss><channel></channel></rss>", "<rss/>", "", "<"].map { Data($0.utf8) }

    /// Nesting past libxml2's bound, a billion laughs, and an external entity on a local file.
    nonisolated static let hostileAppcasts: [String] = {
        let deep = String(repeating: "<a>", count: 10_000) + String(repeating: "</a>", count: 10_000)
        var laughs = #"<!ENTITY l0 "lol">"#
        for level in 1...9 {
            let references = String(repeating: "&l\(level - 1);", count: 10)
            laughs += "<!ENTITY l\(level) \"\(references)\">"
        }
        let item = "<item><title>&x;</title><sparkle:version>1</sparkle:version></item>"
        return [
            "<rss><channel>\(deep)</channel></rss>",
            "<!DOCTYPE rss [\(laughs)<!ENTITY x \"&l9;\">]><rss><channel>\(item)</channel></rss>",
            "<!DOCTYPE rss [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><rss><channel>\(item)</channel></rss>",
            "<!DOCTYPE rss [<!ENTITY % p SYSTEM \"file:///etc/passwd\"> %p;]><rss><channel>\(item)</channel></rss>",
            "<rss><channel><item><sparkle:version>\(String(repeating: "9", count: 4_000))</sparkle:version></item></channel></rss>",
        ]
    }()

    static let whatsNewSeed = Data(#"""
    {"schemaVersion":1,"version":"1.2.3","channel":"nightly","date":"2026-10-10","headline":{"en":"New","de":"Neu"},
     "entries":[
      {"id":"a","category":"new","title":{"en":"A"},"summary":{"en":"S"},"platforms":["macos"],"audience":"all",
       "media":{"kind":"image","light":"media/1.2.3/a.png","dark":"media/1.2.3/b.png","alt":{"en":"x"}},
       "tryIt":{"deeplink":"cmux://settings"},"docs":"https://cmux.com/docs"},
      {"id":"b","category":"fixed","title":{"en":"B"},"summary":{"en":"S"},"platforms":["ios"],"audience":"teams"},
      {"id":"c","category":"security","title":{"en":"C"},"summary":{"en":"S"},"platforms":["cli"],"audience":"all",
       "media":{"kind":"video","light":"media/../../etc/x","dark":"media/x.mp4","alt":{}},"tryIt":{"deeplink":"https://x"},
       "docs":"http://cmux.com"}]}
    """#.utf8)

    static let feedSeeds: [Data] = [
        #"{"version":1,"build":"2026101001","shortVersion":"1.2.3","date":"2026-10-10","highlights":[{"id":"h","title":"T","body":"B","media":[{"url":"https://cmux.com/a.png","sha256":"ab","kind":"image","alt":"a"}],"action":{"id":"a","title":"Try"},"category":"new"}],"changes":["Fix a thing (#123)","Plain","(#)","x (#99999999999999999999)"],"summary":[{"group":"g","title":"t"}]}"#,
        #"{"builds":[{"build":"2026101001","shortVersion":"1.2.3","date":"2026-10-10","highlights":2,"head":"abc"}]}"#,
        #"{"items":[{"id":"a","title":"T","detail":"d","action":"x","minBuild":"1","maxBuild":"9","startsAt":"2026-01-01T00:00:00Z","expiresAt":"2027-01-01T00:00:00Z"}]}"#,
        #"[{"build":"2026101001","reason":"crash","pulledAt":"2026-10-10T00:00:00Z","serve":"2026100901"},{"build":7}]"#,
        #"{"daemon":3,"journal":12,"flag":true}"#, #"{"addresses":["100.64.0.1:7777","[fd7a::1]:7777"]}"#,
        #"{"active":null,"previous":null,"floor":1700000000}"#, #"{"keys":[{"id":"0123456789abcdef","ed25519":"AAAA"}]}"#,
        #"{"fromVersion":"1.2.2","fromBuild":"1","toVersion":"1.2.3","toBuild":"2","stagedAt":"2026-10-10T00:00:00Z","changelog":{}}"#,
    ].map { Data($0.utf8) }

    /// The trusted key's signatures, as CI's web-ota-pointer.py makes them.
    struct Signer {
        let key: Curve25519.Signing.PrivateKey
        let keys: WebUpdateKeys
        let keyID: String

        init() throws {
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
            let raw = key.publicKey.rawRepresentation
            keyID = WebUpdateKeys.id(of: raw)
            keys = WebUpdateKeys(json: try FuzzJSON.object([
                "keys": .array([.object(["id": .string(keyID), "ed25519": .string(raw.base64EncodedString())])]),
            ]).data())
        }

        /// An envelope around `payload`, signed by the trusted key.
        func envelope(_ payload: FuzzJSON) throws -> Data {
            try envelope(bytes: try payload.data())
        }

        /// An envelope around the payload bytes `bytes`, signed by the trusted key.
        func envelope(bytes: Data) throws -> Data {
            let signature = try key.signature(for: bytes)
            return try FuzzJSON.object([
                "schema": .int(1), "payload": .string(bytes.base64EncodedString()),
                "signatures": .array([.object(["key_id": .string(keyID), "sig": .string(signature.base64EncodedString())])]),
            ]).data()
        }

        /// The pointer `data` holds, or nil for any refusal.
        func pointer(_ data: Data) -> WebUpdatePointer? {
            do throws(WebUpdateRefusal) {
                return try WebUpdatePointer.verified(data, keys: keys, channel: AppcastFuzzCases.channel)
            } catch {
                return nil
            }
        }
    }

    static let channel = "nightly"
    static let digest = String(repeating: "ab", count: 32)

    /// A well-formed payload's fields.
    static func pointerFields() -> FuzzJSON {
        .object([
            "schema": .int(1), "channel": .string(channel), "key": .string(String(repeating: "cd", count: 32)),
            "archive": .string("web-bundles-\(digest).tar.gz"), "sha256": .string(digest), "size": .int(123_456),
            "outputs": .string(String(repeating: "ef", count: 32)), "abi": .int(3), "commit": .string(String(repeating: "a1", count: 20)),
            "committed_at": .int(1_760_000_000), "published_at": .int(1_760_000_100),
        ])
    }

    /// A JSON value nested `depth` deep: in arrays, in objects keyed `x`, and in both by turns.
    static func deepValues(depth: Int) -> [String] {
        var mixed = "0"
        for level in 0..<depth { mixed = level.isMultiple(of: 2) ? "[\(mixed)]" : #"{"x":\#(mixed)}"# }
        return [
            String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth),
            String(repeating: #"{"x":"#, count: depth) + "0" + String(repeating: "}", count: depth),
            mixed,
        ]
    }

    /// Feed and CLI documents whose walked fields hold a value nested `depth` deep, and the value alone.
    static func deepDocuments(depth: Int) -> [Data] {
        let texts = deepValues(depth: depth).flatMap { (value: String) -> [String] in
            [
                value,
                #"{"schemaVersion":1,"version":"1.2.3","headline":\#(value),"entries":\#(value)}"#,
                #"{"schemaVersion":1,"version":"1.2.3","entries":[{"id":"a","category":"new","title":\#(value),"summary":{"en":"S"},"platforms":\#(value),"audience":"all","media":\#(value),"tryIt":\#(value)}]}"#,
                #"{"version":1,"build":"1","shortVersion":"1.2.3","highlights":\#(value),"changes":\#(value),"summary":[\#(value)]}"#,
                #"{"builds":\#(value)}"#, #"{"items":[{"id":"a","title":\#(value),"startsAt":\#(value)}]}"#, "[\(value)]",
                #"{"addresses":\#(value)}"#, #"{"keys":\#(value)}"#, #"{"active":\#(value),"previous":\#(value),"floor":1}"#,
                #"{"fromVersion":"1.2.2","changelog":\#(value)}"#, #"{"daemon":\#(value),"journal":1}"#,
                #"{"schema":1,"payload":"e30","signatures":\#(value)}"#,
                #"{"schema":\#(value),"payload":\#(value),"signatures":[{"key_id":\#(value),"sig":"AA"}]}"#,
            ]
        }
        return texts.map { Data($0.utf8) }
    }

    /// Payloads, to be signed by the trusted key, whose fields hold a value nested `depth` deep.
    static func deepPayloads(depth: Int) -> [Data] {
        let texts = deepValues(depth: depth).flatMap { (value: String) -> [String] in
            [
                value,
                #"{"schema":1,"channel":\#(value),"key":"\#(String(repeating: "cd", count: 32))","size":123}"#,
                #"{"schema":\#(value),"channel":"\#(channel)","archive":\#(value),"sha256":"\#(digest)","abi":\#(value)}"#,
            ]
        }
        return texts.map { Data($0.utf8) }
    }

    // MARK: Properties

    /// An appcast: items or `AppcastParseError`; no external entity read; a pick that holds for several builds and systems.
    static func appcast(_ data: Data) throws {
        let items: [AppcastItem]
        do {
            items = try AppcastParser.parse(data)
        } catch {
            try FuzzRun.check(error is AppcastParseError, "the appcast reader threw \(type(of: error))")
            return
        }
        for item in items {
            try FuzzRun.check(item.title?.contains("root:") != true && item.itemDescription?.contains("root:") != true,
                              "an external entity was read into an item")
            for bound in [item.minimumSystemVersion, item.maximumSystemVersion].compactMap(\.self) {
                try FuzzRun.check(bound.major >= 0 && bound.minor >= 0 && bound.patch >= 0, "a negative system version \(bound)")
            }
        }
        let systems = [SystemVersion(major: 14), SystemVersion(major: 15, minor: 6, patch: 1), SystemVersion(major: 26)]
        for build in ["0", "2026101001", "", "1.2.3-beta"] {
            for system in systems {
                try pick(AppcastSelector.select(from: items, currentBuild: build, system: system), build: build, system: system)
            }
        }
    }

    static func pick(_ outcome: UpdateProbeOutcome, build: String, system: SystemVersion) throws {
        switch outcome {
        case .updateAvailable(let item):
            try FuzzRun.check(item.supports(system) && AppcastSelector.isOlder(build, than: item.version),
                              "offered \(item.version) to build \(build) on \(system)")
        case .requiresNewerSystem(let item, _):
            try FuzzRun.check(!item.supports(system), "\(item.version) needs a newer system than \(system), which runs it")
        case .upToDate(let latest):
            try FuzzRun.check(latest?.supports(system) ?? true, "the latest item for \(system) does not run there")
        }
    }

    /// Version text from version characters: what reads, reads back from its own description.
    static func versions(_ rng: inout FuzzRNG) throws {
        let alphabet: [Character] = ["0", "1", "2", "9", ".", ".", "-", "+", " ", "r", "c", "n", "\u{661}", "a"]
        var text = rng.text(alphabet, 24)
        if rng.oneIn(8) { text += String(repeating: "9", count: 20) }
        if let version = SystemVersion(text) {
            try FuzzRun.check(SystemVersion(version.description) == version, "system version \(text) does not read back")
        }
        let prerelease = rng.oneIn(2) ? "" : (rng.bool() ? "-rc." : "-nightly.") + rng.text(alphabet, 8)
        if let version = WhatsNewVersion(text + prerelease) {
            try FuzzRun.check(WhatsNewVersion(version.description) == version, "What's New version \(text + prerelease) does not read back")
        }
        let subject = FuzzJSON.randomString(&rng, limit: 24) + (rng.bool() ? " (#\(rng.text(alphabet, 12)))" : "")
        let item = ReleaseNotes.ChangeItem(subject: subject)
        try FuzzRun.check(item.pr.map { $0 >= 0 } ?? true, "commit subject \(subject) reads as PR \(String(describing: item.pr))")
        _ = (item.url, item.prLabel)
    }

    /// A What's New document: refused, or one this Mac may show.
    static func whatsNew(_ data: Data) throws {
        for origin in [WhatsNewDocument.Origin.bundled, .feed] {
            guard let document = WhatsNewDocument.decode(data, origin: origin) else { continue }
            try FuzzRun.check(document.schemaVersion == 1 && document.parsedVersion != nil && document.origin == origin,
                              "a document of schema \(document.schemaVersion), version \(document.version) was kept")
            for entry in document.entries {
                try FuzzRun.check(entry.isForMac, "entry \(entry.id) is for \(entry.platforms)")
                try FuzzRun.check(entry.media.map { $0.light.hasPrefix("media/") && $0.dark.hasPrefix("media/") } ?? true,
                                  "entry \(entry.id) keeps media outside media/")
                try FuzzRun.check(entry.media.map { !"\($0.light)/\($0.dark)".split(separator: "/").contains("..") } ?? true,
                                  "entry \(entry.id) keeps a media path with ..")
                try FuzzRun.check(entry.docs.map { $0.scheme == "https" } ?? true, "entry \(entry.id) keeps docs \(String(describing: entry.docs))")
                try FuzzRun.check(entry.tryIt?.deeplink.map { $0.hasPrefix("cmux://") } ?? true, "entry \(entry.id) keeps a foreign deeplink")
            }
        }
    }

    /// A damaged envelope gives the signed pointer or nothing.
    static func envelope(_ data: Data, signer: Signer) throws {
        guard let pointer = signer.pointer(data) else { return }
        let genuine = signer.pointer(try signer.envelope(pointerFields()))
        try FuzzRun.check(pointer == genuine, "a damaged envelope gave another pointer: \(pointer)")
    }

    /// A payload the trusted key signed, its fields right, wrong or missing: taken only when well formed.
    static func signedPayload(_ rng: inout FuzzRNG, signer: Signer) throws {
        guard case var .object(fields) = pointerFields() else { return }
        for key in fields.keys.sorted() where rng.oneIn(6) {
            switch rng.below(4) {
            case 0: fields[key] = nil
            case 1: fields[key] = FuzzJSON.random(&rng, depth: 1)
            case 2: fields[key] = .string(rng.text(["a", "b", "0", "9", "F", "-", "/", "."], 70))
            default: fields[key] = .int(Int64(rng.int(in: -2...Int(Int32.max))) * (rng.oneIn(4) ? 1_000 : 1))
            }
        }
        guard let pointer = signer.pointer(try signer.envelope(.object(fields))) else { return }
        func hex(_ text: String, _ count: Int) -> Bool {
            text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        try FuzzRun.check(pointer.channel == channel && hex(pointer.key, 64) && hex(pointer.sha256, 64) && hex(pointer.outputs, 64)
                              && hex(pointer.commit, 40) && pointer.archive == "web-bundles-\(pointer.sha256).tar.gz"
                              && (1...WebUpdatePointer.maximumSize).contains(pointer.size) && pointer.abi > 0 && pointer.committedAt > 0,
                          "a malformed signed pointer was taken: \(pointer)")
    }

    /// The feed and CLI JSON the updater reads besides the appcast.
    static func feedJSON(_ data: Data) throws {
        if let notes = try? JSONDecoder().decode(ReleaseNotes.self, from: data) {
            for item in notes.changeItems { _ = (item.url, item.prLabel) }
            if let document = notes.whatsNew { _ = document.parsedVersion }
        }
        _ = try? JSONDecoder().decode([ReleaseNotesIndexEntry].self, from: data)
        nonisolated struct Feed: Decodable { var items: [Announcement] }
        if let feed = try? JSONDecoder().decode(Feed.self, from: data) {
            let dismissed: Set<String> = feed.items.first.map { [$0.id] } ?? []
            let shown = AnnouncementFilter.visible(feed.items, build: "2026101001", now: Date(timeIntervalSince1970: 1_790_000_000),
                                                   dismissed: dismissed)
            try FuzzRun.check(shown.count <= 3 && shown.allSatisfy { !dismissed.contains($0.id) }, "\(shown.count) announcements shown")
        }
        _ = PulledBuild.decode(data)
        _ = StoreSchemaProbe.parse(data)
        if let address = ServerTailnetAddress(hostStatus: data) {
            try FuzzRun.check(!address.value.isEmpty, "an empty tailnet address")
        }
        if let state = try? JSONDecoder().decode(WebUpdateState.self, from: data) { _ = state.keptKeys }
        _ = WebUpdateKeys(json: data).keys.count
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        _ = try? decoder.decode(WhatsNewLastUpdate.self, from: data)
    }
}
