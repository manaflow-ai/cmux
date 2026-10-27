import CmuxFuzzSupport
@testable import CmuxNextBrowser
import CoreGraphics
import Foundation
import Testing

/// Seeded fuzz of what the Chromium side sends cmux (plans/cmux-next/chrome-parity/p10-stability.md, task 180):
/// DevTools (CDP) messages and their top-level id, every JSON reply of the CEF shim and the fork (navigation
/// entries, cookies, certificates, passwords, passkeys, extensions, context and popup menus, the side panel,
/// device emulation, bookmarks, Page Info, script results), a page's posted messages, a helper's argv, and in
/// Debug the Chromium host wire: input frames, control frames and the mirror they fill. Garbage, truncated and
/// deeply nested input. Chrome fuzzes the same boundaries: its DevTools protocol parser
/// (third_party/inspector_protocol/crdtp/json_fuzzer.cc), its JSON reader (base/json/json_reader_fuzzer.cc) and
/// Mojo messages from a renderer (mojo/public/tools/fuzzers/mojo_parse_message_fuzzer.cc).
///
/// The properties:
/// - no input traps; a decoder returns a value or refuses (nil, an empty list, a typed error);
/// - a message's top-level id, once replaced, reads back as the new id, and agrees with a full JSON parse;
/// - a context menu has no hidden row, no leading, trailing or doubled separator and no empty submenu;
/// - an input frame and a control frame re-encode to the bytes they came from, and a stream of frames split
///   anywhere decodes to the same frames;
/// - the mirror takes exactly the well-formed MIRROR and ACK frames and marks nothing pending;
/// - a page message passes only on a known channel, within its size, from a frame the channel accepts.
///
/// It runs only with `CMUX_CEF_FUZZ=1`; agents run it on the fleet, CI does not (Lawrence 2026-10-23):
///
/// ```
/// CMUX_CEF_FUZZ=1 swift test --filter CEFMessageFuzzTests
/// CMUX_CEF_FUZZ=1 CMUX_FUZZ_DEADLINE=$(( $(date +%s) + 300 )) swift test --filter CEFMessageFuzzTests
/// ```
///
/// The runs are CmuxFuzzSupport `FuzzRun`s (p10-stability-016): `CMUX_FUZZ_SEED` and `CMUX_FUZZ_ITERATIONS`
/// replay a failure, and with `CMUX_FUZZ_ARTIFACTS` set a trap leaves its input behind. Inputs stay under the
/// main thread's JSON gate (`BlockingKind.cpuIntensiveJSONBytes`): these decoders run on main in the app too.
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_CEF_FUZZ"] == "1",
        "set CMUX_CEF_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
struct CEFMessageFuzzTests {
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
        case 0: try CEFMessageFuzzCases.cdp(bytes)
        case 1: try CEFMessageFuzzCases.shimReply(bytes)
        case 2: try CEFMessageFuzzCases.procArgs(bytes)
        default: try CEFMessageFuzzCases.hostWire(bytes)
        }
    }

    @Test(.timeLimit(.minutes(CEFMessageFuzzTests.timeLimitMinutes)))
    func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("CEFMessage.oneInput", seed: 0xCEF0_0180_0001, iterations: 4_000)
        let tapes: [[UInt8]] = [[0], [1], [2], [3], [0, 40, 123, 34, 105, 100, 34, 58, 49, 125], [3, 64, 9, 9, 9]]
        try run.forEachInput(try run.corpus(seeds: tapes.map { Data($0) })) { try Self.oneInput($0) }
    }

    /// CDP messages with JSON-token edits: the top-level id scan never traps, a replaced id reads back, and an
    /// id it finds is the one a full parse finds.
    @Test(.timeLimit(.minutes(CEFMessageFuzzTests.timeLimitMinutes)))
    func cdpMessagesKeepTheirTopLevelID() throws {
        let run = try FuzzRun("CEFMessage.cdp", seed: 0xCEF0_0180_0002, iterations: 20_000)
        let mutator = FuzzMutator(dictionary: CEFMessageFuzzCases.jsonTokens, maximumEdits: 6, maximumCount: 1 << 14)
        try run.forEachInput(try run.corpus(seeds: CEFMessageFuzzCases.cdpSeeds), mutator: mutator) {
            try CEFMessageFuzzCases.cdp($0)
        }
    }

    /// Every shim and fork reply format, damaged by byte and token edits, through every decoder.
    @Test(.timeLimit(.minutes(CEFMessageFuzzTests.timeLimitMinutes)))
    func shimRepliesDecodeOrAreRefused() throws {
        let run = try FuzzRun("CEFMessage.shim", seed: 0xCEF0_0180_0003, iterations: 6_000)
        let mutator = FuzzMutator(dictionary: CEFMessageFuzzCases.jsonTokens, maximumEdits: 6, maximumCount: 1 << 14)
        try run.forEachInput(try run.corpus(seeds: CEFMessageFuzzCases.replySeeds), mutator: mutator) {
            try CEFMessageFuzzCases.shimReply($0)
        }
    }

    /// Well-formed JSON with the fields the decoders read, each of the right type or a wrong one, among others.
    @Test(.timeLimit(.minutes(CEFMessageFuzzTests.timeLimitMinutes)))
    func wrongTypesDecodeOrAreRefused() throws {
        try FuzzRun("CEFMessage.types", seed: 0xCEF0_0180_0004, iterations: 6_000).forEach { rng in
            let data = try CEFMessageFuzzCases.typedReply(&rng).data()
            try CEFMessageFuzzCases.shimReply(data)
            try CEFMessageFuzzCases.cdp(data)
        }
    }

    /// Nesting at and past the JSON parsers' bound, in every field a decoder walks: refused or parsed, never a
    /// stack overflow in the decoders that recurse (frame trees, menus, script values).
    @Test(.timeLimit(.minutes(CEFMessageFuzzTests.timeLimitMinutes)), arguments: [1, 64, 255, 256, 511, 512, 513, 2_000])
    func deepNestingIsRefusedOrParsed(depth: Int) throws {
        for data in CEFMessageFuzzCases.deepReplies(depth: depth) {
            try CEFMessageFuzzCases.shimReply(data)
            try CEFMessageFuzzCases.cdp(data)
        }
    }

    /// A helper's KERN_PROCARGS2 buffer, cut and damaged anywhere.
    @Test(.timeLimit(.minutes(CEFMessageFuzzTests.timeLimitMinutes)))
    func helperArgvNeverTraps() throws {
        let run = try FuzzRun("CEFMessage.procArgs", seed: 0xCEF0_0180_0005, iterations: 20_000)
        let mutator = FuzzMutator(dictionary: CEFMessageFuzzCases.argvTokens, maximumCount: 1 << 12)
        try run.forEachInput(try run.corpus(seeds: CEFMessageFuzzCases.procArgsSeeds), mutator: mutator) {
            try CEFMessageFuzzCases.procArgs($0)
        }
    }

    /// `cmuxPost` from a page: any channel name, payload size and frame.
    @Test(.timeLimit(.minutes(CEFMessageFuzzTests.timeLimitMinutes)))
    func pageMessagesPassOnlyWithinTheirBounds() throws {
        try FuzzRun("CEFMessage.page", seed: 0xCEF0_0180_0006, iterations: 4_000).forEach { rng in
            try CEFMessageFuzzCases.pageMessage(&rng)
        }
    }

    /// A script result (EVALUATE_RESULT) of any status and text, parsed off main as the tab parses it.
    @Test(.timeLimit(.minutes(CEFMessageFuzzTests.timeLimitMinutes)))
    func scriptResultsParseOrThrowTyped() async throws {
        let run = try FuzzRun("CEFMessage.evaluate", seed: 0xCEF0_0180_0007, iterations: 2_000)
        let mutator = FuzzMutator(dictionary: CEFMessageFuzzCases.jsonTokens, maximumEdits: 6, maximumCount: 1 << 14)
        let seeds = [#"{"a":[1,2.5,"x",null,true]}"#, #""text""#, "42", "", "[", #"{"deep":[[[[{}]]]]}"#].map { Data($0.utf8) }
        try await run.forEachInputAwaiting(try run.corpus(seeds: seeds), mutator: mutator) { data in
            try await CEFMessageFuzzCases.evaluation(data)
        }
    }

    #if DEBUG
    /// Chromium host input frames: any bytes decode to whole frames that re-encode to the same bytes, need
    /// more, or are refused.
    @Test(.timeLimit(.minutes(CEFMessageFuzzTests.timeLimitMinutes)))
    func hostFramesReencodeToTheirBytes() throws {
        let run = try FuzzRun("CEFMessage.hostFrame", seed: 0xCEF0_0180_0008, iterations: 20_000)
        var seedRNG = FuzzRNG(seed: 0xCEF0_0180_0108)
        let seeds = (0..<8).map { _ in Data(CEFMessageFuzzCases.frames(&seedRNG).flatMap { $0.encoded() }) }
        let mutator = FuzzMutator(dictionary: CEFMessageFuzzCases.binaryTokens, maximumCount: 1 << 14)
        try run.forEachInput(try run.corpus(seeds: seeds), mutator: mutator) { try CEFMessageFuzzCases.hostFrames($0) }
    }

    /// A stream of frames read in pieces cut anywhere gives the frames that were sent, in order.
    @Test(.timeLimit(.minutes(CEFMessageFuzzTests.timeLimitMinutes)))
    func hostFrameStreamsSplitAnywhere() throws {
        try FuzzRun("CEFMessage.hostStream", seed: 0xCEF0_0180_0009, iterations: 4_000).forEach { rng in
            try CEFMessageFuzzCases.hostStream(&rng)
        }
    }

    /// Control channel frames: any bytes (with no descriptors received) decode to messages that re-encode to
    /// the same bytes, need more, or are malformed; the mirror takes them without a trap.
    @Test(.timeLimit(.minutes(CEFMessageFuzzTests.timeLimitMinutes)))
    func controlFramesReencodeToTheirBytes() throws {
        let run = try FuzzRun("CEFMessage.control", seed: 0xCEF0_0180_000A, iterations: 20_000)
        var seedRNG = FuzzRNG(seed: 0xCEF0_0180_010A)
        let seeds = (0..<8).map { _ in
            Data((0..<3).flatMap { _ in CEFMessageFuzzCases.controlMessage(&seedRNG).encoded() ?? [] })
        }
        let mutator = FuzzMutator(dictionary: CEFMessageFuzzCases.binaryTokens, maximumCount: 1 << 14)
        try run.forEachInput(try run.corpus(seeds: seeds), mutator: mutator) { try CEFMessageFuzzCases.controlFrames($0) }
    }

    /// MIRROR and ACK frames built near the valid shape: the mirror takes exactly the well-formed ones.
    @Test(.timeLimit(.minutes(CEFMessageFuzzTests.timeLimitMinutes)))
    func mirrorTakesExactlyTheWellFormedFrames() throws {
        let mirror = ChromiumHostMirror()
        try FuzzRun("CEFMessage.mirror", seed: 0xCEF0_0180_000B, iterations: 10_000).forEach { rng in
            try CEFMessageFuzzCases.mirrorFrame(&rng, into: mirror)
        }
        mirror.hostEnded()
    }
    #endif
}

/// The fixed cases the fuzz found (p10-stability-180); they run on every `swift test`.
@MainActor
@Suite struct CEFMessageDecodeTrapTests {
    /// A tab record whose `chromium_calls` is not a list reads with no calls. Before, the record went back
    /// through `JSONSerialization.data(withJSONObject:)`, which raises an Objective-C exception for a top-level
    /// string, number or null, and the app ended.
    @Test(arguments: [#""x""#, "5", "null", "true", #"{"a":1}"#])
    func aCallListThatIsNoListReadsAsNoCalls(calls: String) throws {
        let record = Data(#"{"width":390,"height":844,"device_scale_factor":3,"chromium_calls":\#(calls)}"#.utf8)
        let emulation = try #require(BrowserEmulation(record: record))
        #expect(emulation.chromiumCallsJSON == "[]")
        #expect(emulation.width == 390)
    }

    @Test func aCallListKeepsItsCalls() throws {
        let record = Data(#"{"width":390,"height":844,"device_scale_factor":3,"chromium_calls":[{"m":"x"}]}"#.utf8)
        let emulation = try #require(BrowserEmulation(record: record))
        #expect(emulation.chromiumCallsJSON == #"[{"m":"x"}]"#)
    }
}

/// The inputs and properties of ``CEFMessageFuzzTests``.
@MainActor
enum CEFMessageFuzzCases {
    // MARK: Inputs

    /// JSON structure plus the keys and values the decoders read.
    static let jsonTokens: [Data] = FuzzJSON.tokens + [
        #""id""#, #""sessionId""#, #""method""#, #""result""#, #""params""#, #""entries""#, #""current""#, #""cookies""#,
        #""passwords""#, #""exceptions""#, #""op""#, #""header""#, #""open""#, #""fit""#, #""mode""#, #""chromium_calls""#,
        #""frameTree""#, #""childFrames""#, #""resources""#, #""items""#, #""type""#, #""submenu""#, #""separator""#,
        #""visible""#, #""data""#, #""chain""#, #""exceptionDetails""#, #""value""#, #""1073741824""#, "1073741824",
        "2147483647", "2147483648", "999999999999999999", "1e18", "-1", "0.0",
    ].map { Data($0.utf8) }

    /// Header words of the host wire: kinds, lengths at and past the bound, flags.
    static let binaryTokens: [Data] = ([
        [0, 0, 0, 0], [1, 0, 0, 0], [101, 0, 0, 0], [0xFF, 0xFF, 0xFF, 0xFF], [0, 0, 1, 0], [1, 0, 1, 0],
        [0x03, 0x80], [0x04, 0x80], [0x08, 0x00], [0x07, 0x00], [5, 1, 0xFF, 0xFF], [6, 1, 8, 0], [7, 1, 8, 0],
        [0xC3, 0x28], [0xED, 0xA0, 0x80],
    ] as [[UInt8]]).map { Data($0) }

    static let argvTokens: [Data] = ["--type=", "renderer", "--utility-sub-type=", "--extension-process", "\u{0}"]
        .map { Data($0.utf8) } + [Data([0xFF, 0xFF, 0xFF, 0x7F]), Data([0, 0, 0, 0x80])]

    static let cdpSeeds: [Data] = [
        #"{"id":1073741825,"method":"Runtime.evaluate","params":{"expression":"1+1","returnByValue":true}}"#,
        #"{"id":7,"result":{"result":{"type":"number","value":2}},"sessionId":"8F2A"}"#,
        #"{"method":"Page.loadEventFired","params":{"timestamp":12.5}}"#,
        #" { "sessionId" : "x" , "id" : -42 , "error" : {"code":-32000,"message":"no"} } "#,
        #"{"id":1,"id":2}"#, #"{"id":1.5}"#, #"{"id":"1"}"#, #"{"a":"}\"","id":3}"#, "{}", "[]", "",
    ].map { Data($0.utf8) }

    static let replySeeds: [Data] = [
        #"{"entries":[{"url":"https://a.test/","title":"A"},{"url":"about:blank","title":""}],"current":1}"#,
        #"[{"name":"sid","domain":".a.test","path":"/"},{"name":"x","domain":"b.test"}]"#,
        #"{"secure":true,"certStatus":0,"contentStatus":1,"url":"https://a.test/","chain":["MIIB","AAAA"]}"#,
        #"{"cookies":[{"name":"a","value":"b","domain":"a.test","path":"/","expires":1.9e9,"session":false,"secure":true,"httpOnly":true}]}"#,
        #"{"passwords":[{"id":"12","site":"a.test","url":"https://a.test/","username":"me","created":1.7e12,"last_used":0,"times_used":3,"weak":true,"reused":false}],"exceptions":[{"id":"4","site":"b.test"}]}"#,
        #"[{"rp_id":"a.test","credential_id":"AbC","user_name":"me","user_display_name":"Me"}]"#,
        #"{"written":3,"rejected":1}"#, #"{"added":1,"duplicate":0,"conflict":2,"rejected":0,"conflicts":[0,4]}"#,
        #"{"updated":1,"missing":0,"rejected":-1}"#,
        #"[{"id":"abc","name":"Ext","version":"1.0","manifest_version":3,"location":"internal","enabled":true,"disable_reasons":[1],"options_url":"chrome-extension://abc/o.html","path":"/tmp/x"}]"#,
        #"[{"extension_id":"abc","name":"_execute_action","description":"Run","key_code":65,"modifiers":18,"shortcut":"Ctrl+A","global":false}]"#,
        ##"[{"id":"abc","name":"Ext","title":"T","badge":"9","badge_color":"#FF0000FF","badge_text_color":"#FFF","enabled":true,"icon_png":"iVBORw0K"}]"##,
        #"[{"id":1,"label":"&Back","type":"command"},{"id":0,"type":"separator"},{"id":2,"label":"More","type":"submenu","items":[{"id":3,"type":"separator"},{"id":4,"label":"Hidden","visible":false}]},{"id":5,"type":"separator"}]"#,
        #"{"x":40,"y":-12,"width":240,"height":32,"fontSize":13.5,"selected":1,"rightAligned":true,"items":[{"label":"A","toolTip":"","type":0,"enabled":true,"checked":false,"rtl":false,"directionOverride":false}]}"#,
        #"{"open":true,"title":"Panel","icon_png":"","pin_visible":true,"pinned":false,"focusable_controls":2,"header":{"x":0,"y":0,"width":320,"height":40}}"#,
        #"{"manifest_version":3,"permissions":["activeTab","https://*/*","<all_urls>"],"host_permissions":["https://a.test/*"],"content_scripts":[{"matches":["https://a.test/*"]}],"side_panel":{"default_path":"p.html"},"action":{"default_popup":"x.html"}, /* json5 */ }"#,
        #"{"mode":"fit","fit":{"aspect_width":9,"aspect_height":16,"min_width":320,"max_width":0,"value":"9:16"},"chromium_calls":[{"method":"Emulation.setDeviceMetricsOverride"}]}"#,
        #"{"width":390,"height":844,"device_scale_factor":3,"user_agent":"UA","device":"iPhone","orientation":"vertical","orientations":["vertical","horizontal"]}"#,
        #"{"devices":[{"title":"Phone","screen":{"vertical":{"width":390,"height":844},"device-pixel-ratio":3},"show-by-default":true,"origin":"custom"}]}"#,
        #"["cmux",["cmux terminal","cmux next"],[],{}]"#,
        #"{"op":"added","nodes":[{"id":"1","parent":"0","index":0,"kind":"folder","title":"Bar","added_ms":1.7e12}]}"#,
        #"{"op":"moved","id":"1","parent":"2","index":3}"#, #"{"op":"reordered","parent":"2","children":["1","3"]}"#,
        #"{"tableNames":["MIIB","bad base64"]}"#,
        #"{"frameTree":{"frame":{"url":"https://a.test/"},"resources":[{"url":"http://b.test/x.js"}],"childFrames":[{"frame":{"url":"https://c.test/"}}]}}"#,
        #"{"result":{"type":"object","value":{"a":[1,"b",null]}}}"#, #"{"exceptionDetails":{"text":"boom"}}"#,
        #"{"data":"iVBORw0KGgo="}"#, #"{"frameTree":{"frame":{"id":"F1"}}}"#, #"{"executionContextId":12}"#,
    ].map { Data($0.utf8) }

    /// argc 3, the exec path, NUL padding, then argv.
    static let procArgsSeeds: [Data] = [
        Data([3, 0, 0, 0]) + Data("/Applications/cmux.app/Contents/Frameworks/Helper\u{0}\u{0}\u{0}\u{0}".utf8)
            + Data("Helper\u{0}--type=renderer\u{0}--extension-process\u{0}--utility-sub-type=x\u{0}".utf8),
        Data([1, 0, 0, 0]), Data([0xFF, 0xFF, 0xFF, 0xFF]) + Data("x\u{0}y".utf8), Data(),
    ]

    /// An object with the fields the decoders read, of a right or wrong type, nested up to three deep.
    static func typedReply(_ rng: inout FuzzRNG) -> FuzzJSON {
        let keys = ["id", "sessionId", "result", "value", "type", "entries", "current", "url", "title", "name", "domain",
                    "path", "cookies", "expires", "session", "passwords", "exceptions", "op", "nodes", "index", "kind",
                    "parent", "children", "open", "header", "width", "height", "x", "y", "mode", "fit", "chromium_calls",
                    "frameTree", "frame", "childFrames", "resources", "items", "label", "visible", "data", "chain",
                    "devices", "screen", "vertical", "tableNames", "exceptionDetails", "executionContextId"]
        var fields: [String: FuzzJSON] = [:]
        for _ in 0..<(1 + rng.below(8)) {
            if let key = rng.element(of: keys) { fields[key] = FuzzJSON.random(&rng, depth: 3) }
        }
        switch rng.below(4) {
        case 0: return .array([.object(fields), FuzzJSON.random(&rng, depth: 2)])
        case 1: return FuzzJSON.random(&rng, depth: 3)
        default: return .object(fields)
        }
    }

    /// Replies whose walked fields are nested `depth` deep. A frame tree or menu level is two JSON levels, so
    /// 400 of them pass the parsers' bound and stay under the main thread's JSON gate.
    static func deepReplies(depth: Int) -> [Data] {
        let arrays = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        var frameTree = #"{"frame":{"url":"https://a.test/"}}"#
        var menu = #"[{"id":0,"label":"leaf"}]"#
        for level in 0..<min(depth, 400) {
            frameTree = #"{"frame":{"url":"https://f\#(level % 7).test/"},"childFrames":[\#(frameTree)]}"#
            menu = #"[{"id":\#(level),"type":"submenu","label":"m","items":\#(menu)}]"#
        }
        let texts = [
            arrays, #"{"entries":\#(arrays),"id":1}"#, #"{"result":{"value":\#(arrays)}}"#,
            #"{"frameTree":\#(frameTree)}"#, menu, #"{"cookies":[\#(arrays)]}"#, #"{"op":"added","nodes":\#(arrays)}"#,
            #"{"id":5,"params":\#(arrays)}"#,
        ]
        return texts.map { Data($0.utf8) }
    }

    // MARK: Properties

    /// The top-level id scan of a CDP message.
    static func cdp(_ data: Data) throws {
        let text = String(decoding: data, as: UTF8.self)
        let id = CEFDevToolsRawMessage.topLevelID(in: text)
        _ = CEFDevToolsRawMessage.sessionID(in: text)
        let raw = CEFDevToolsRawMessage.firstRawID + data.count
        if let replaced = CEFDevToolsRawMessage.replacingTopLevelID(in: text, with: raw) {
            try FuzzRun.check(id != nil, "an id was replaced in a message the scan finds none in: \(text.prefix(120))")
            try FuzzRun.check(CEFDevToolsRawMessage.topLevelID(in: replaced) == raw,
                              "the replaced id \(raw) does not read back from \(replaced.prefix(120))")
        } else {
            try FuzzRun.check(id == nil, "the scan finds id \(String(describing: id)) but nothing replaces it")
        }
        // Without escapes a key is its bytes, so the scan and a full parse see the same "id".
        guard let id, !text.utf8.contains(UInt8(ascii: "\\")),
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        try FuzzRun.check((object["id"] as? NSNumber)?.int64Value == Int64(id),
                          "the scan reads id \(id), a full parse \(String(describing: object["id"])): \(text.prefix(120))")
    }

    /// Every JSON reply decoder of the shim and the fork.
    static func shimReply(_ data: Data) throws {
        let json = String(decoding: data, as: UTF8.self)
        if let history = CEFNavigationEntries(json: json) {
            try FuzzRun.check(history.current == nil || history.entries.indices.contains(history.currentIndex),
                              "a current entry outside the list")
        }
        for cookie in CEFCookie.parse(json) { _ = cookie.matches(host: cookie.host) }
        if let status = CEFSSLStatus.parse(json) { _ = (status.hasCertificateError, status.hasMixedContent) }
        for cookie in CEFCookieStore.parseCookies(json) ?? [] {
            try FuzzRun.check(cookie.expires.map { $0.timeIntervalSince1970 > 0 } ?? true, "a cookie expires at or before 1970")
        }
        try passwords(json)
        for info in BrowserExtensionInfo.decodeList(json) { _ = (info.canRemove, info.canToggle) }
        for command in BrowserExtensionCommand.decodeList(json) { _ = (command.key, command.isExecuteAction) }
        for action in CEFExtensionAction.decodeList(json) {
            for color in [action.badgeColor, action.badgeTextColor] {
                guard let rgba = CEFExtensionAction.rgba(color) else { continue }
                let parts = [rgba.red, rgba.green, rgba.blue, rgba.alpha]
                try FuzzRun.check(parts.allSatisfy { (0...1).contains($0) }, "badge color \(color) reads as \(parts)")
            }
        }
        try menu(BrowserContextMenuItem.decodeList(json))
        if let popup = ChromiumHostPopupMenu(json: json) { _ = (popup.bounds, popup.items.map(\.isChoosable)) }
        if let panel = CEFSidePanelState(json: json) {
            try FuzzRun.check(panel.header.width > 0 && panel.header.height > 0, "a side panel header with no area")
            _ = panel.headerFrame(inPage: CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        if let facts = ExtensionManifestFacts(json: data) {
            try FuzzRun.check(Set(facts.hostPatterns).count == facts.hostPatterns.count, "a site pattern listed twice")
        }
        if let emulation = BrowserEmulation(record: data) {
            let page = CGRect(x: 0, y: 0, width: 1_200, height: 800)
            _ = (emulation.viewport(in: page.size), emulation.presentedRect(in: page), emulation.fitScale(in: page.size))
        }
        _ = (BrowserDeviceMenu.devices(list: data).count, BrowserDeviceMenu.current(record: data) == nil)
        _ = OmniboxRemoteSuggestions.parse(data)
        _ = CEFBookmarkEvent(json: json)
        _ = CEFPageInfoParsing.certificates(json)
        let origins = CEFPageInfoParsing.resourceOrigins(json)
        try FuzzRun.check(Set(origins).count == origins.count, "an origin listed twice")
        _ = try? CEFDevToolsResult.evaluation(json)
        _ = try? CEFDevToolsResult.screenshot(json)
        _ = (CEFDevToolsResult.mainFrameID(json), CEFDevToolsResult.executionContextID(json))
    }

    static func passwords(_ json: String) throws {
        if let list = ChromiumPasswordList.parse(json) {
            try FuzzRun.check(list.passwords.allSatisfy { !$0.id.isEmpty } && list.exceptions.allSatisfy { !$0.id.isEmpty },
                              "a saved sign-in or exception without an id")
        }
        try FuzzRun.check(ChromiumPasskey.parse(json)?.allSatisfy { !$0.credentialID.isEmpty } ?? true, "a passkey without an id")
        _ = ChromiumCookieWriteResult.parse(json)
        _ = ChromiumPasswordWriteResult.parse(json)?.storeFailed
        _ = ChromiumPasswordReplaceResult.parse(json)?.storeFailed
    }

    /// A menu as Chrome shows it: no hidden row, no leading, trailing or doubled separator, no submenu
    /// without a row to choose, at every level.
    static func menu(_ items: [BrowserContextMenuItem]) throws {
        try FuzzRun.check(items.allSatisfy(\.isVisible), "a hidden row shows")
        try FuzzRun.check(items.first?.kind != .separator && items.last?.kind != .separator, "a menu starts or ends with a separator")
        for (row, next) in zip(items, items.dropFirst()) {
            try FuzzRun.check(row.kind != .separator || next.kind != .separator, "two separators in a row")
        }
        for item in items where item.kind == .submenu {
            try FuzzRun.check(item.children.contains { $0.kind != .separator }, "a submenu with nothing to choose")
            try menu(item.children)
        }
    }

    /// A helper's argv from its KERN_PROCARGS2 buffer.
    static func procArgs(_ data: Data) throws {
        let bytes = [UInt8](data)
        let arguments = CEFHelperIdentity.parseProcArgs(bytes)
        try FuzzRun.check(arguments.count <= bytes.count, "\(arguments.count) arguments from \(bytes.count) bytes")
        if let identity = CEFHelperIdentity.parse(arguments) {
            try FuzzRun.check(!identity.processType.isEmpty, "a helper identity without a process type")
        }
    }

    /// A page's `cmuxPost`: a known channel or random text, a payload around the bound, either frame.
    static func pageMessage(_ rng: inout FuzzRNG) throws {
        let known = CEFPageMessage.Channel.allCases.map(\.name)
        let name = rng.oneIn(4) ? FuzzJSON.randomString(&rng, limit: 24) : (rng.element(of: known) ?? "")
        let limit = CEFPageMessage.maxPayloadBytes
        let size = rng.oneIn(16) ? limit - 2 + rng.below(5) : rng.below(512)
        let unit: String = rng.oneIn(3) ? "é" : "a"
        let payload = String(repeating: unit, count: rng.oneIn(2) ? size : size / 2)
        let mainFrame = rng.bool()
        let message = CEFPageMessage(channel: name, payload: payload, mainFrame: mainFrame)
        guard let message else { return }
        try FuzzRun.check(known.contains(name) && message.channel.name == name, "a message on unknown channel \(name)")
        try FuzzRun.check(message.payload.utf8.count <= limit, "a payload of \(message.payload.utf8.count) bytes passed")
        try FuzzRun.check(mainFrame || !message.channel.mainFrameOnly, "a child frame passed on \(name)")
    }

    /// The Chromium host wire's input and control frames in `data`; the host ships in Debug builds only.
    static func hostWire(_ data: Data) throws {
        #if DEBUG
        try hostFrames(data)
        try controlFrames(data)
        #endif
    }

    /// A script result of any status: status 1 parses or throws `javaScript`, 0 and -2 throw `javaScript`,
    /// any other is `closed`.
    static func evaluation(_ data: Data) async throws {
        let status = Int(data.first ?? 0) % 5 - 2
        let result = CEFEvaluationResult(status: status, text: String(decoding: data.dropFirst(), as: UTF8.self))
        let outcome: Result<BrowserJSValue, BrowserTabError>
        do throws(BrowserTabError) {
            outcome = .success(try await result.value())
        } catch {
            outcome = .failure(error)
        }
        switch outcome {
        case .success: try FuzzRun.check(status == 1, "status \(status) gave a value")
        case .failure(.javaScript): try FuzzRun.check([1, 0, -2].contains(status), "status \(status) threw a script error")
        case .failure(.closed): try FuzzRun.check(![1, 0, -2].contains(status), "status \(status) threw closed")
        case .failure(let error): try FuzzRun.check(false, "status \(status) threw \(error)")
        }
    }
}
