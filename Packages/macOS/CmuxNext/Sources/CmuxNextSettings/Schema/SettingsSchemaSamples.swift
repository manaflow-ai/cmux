import CryptoKit
import Foundation

/// Candidate values per setting kind for the schema export: the export keeps
/// the ones `SettingDescriptor.accepts` accepts under `accepts` and the ones
/// it refuses under `refuses`, so another validator (the daemon's config
/// actor) can prove it agrees with Swift on every row.
nonisolated enum SettingsSchemaSamples {
    static func samples(for descriptor: SettingDescriptor) -> (accept: [JSONValue], refuse: [JSONValue]) {
        switch descriptor.kind {
        case .toggle:
            return ([.bool(true), .bool(false)], [.string("true"), .number(1), .null])
        case .choice(let choices):
            if descriptor.path == BackdropSelectionSetting().configPath {
                return (BackdropSelectionSetting.acceptedSamples, BackdropSelectionSetting.refusedSamples)
            }
            return (choices.map { .string($0.value) }, [.string("__not_a_choice__"), .number(1), .bool(true)])
        case .choiceOrNumber(let choices, let number):
            return (choices.map { .string($0.value) } + numbers(number).accept,
                    [.string("__not_a_choice__"), .bool(true)] + numbers(number).refuse)
        case .number(let number):
            return numbers(number)
        case .color:
            return ([.string("#1a2B3c"), .string("#1A2B3C80"), .string("1a2b3c")],
                    [.string("red"), .string("#12345"), .string("#1234567"), .string("#12345g"), .number(0)])
        case .sound, .theme, .fontFamily:
            // Valid names depend on the machine; only the shape is portable.
            return ([], [.number(1), .bool(true), .null])
        case .url where BrowserOmnibarSetting.templatePaths.contains(descriptor.path):
            return ([.string(""), .string("https://search.example/?q=%s"), .string("https://search.example/find?q={searchTerms}")],
                    [.string("https://search.example/"), .string("search.example"), .string("not a url %s"), .number(1)])
        case .url:
            return ([.string(""), .string("https://cmux.com"), .string("example.com/path"), .string("about:blank"), .string("file:///tmp/a.html")],
                    [.string("not a url"), .string("ftp://example.com"), .string("localhost"), .number(1)])
        case .hostList:
            return ([.array([]), .array([.string("localhost"), .string("*.example.com")])],
                    [.string("localhost"), .array([.number(1)])])
        case .folderList:
            return ([.array([]), .array([.string("/Users/ada/src"), .string("~/notes")])],
                    [.string("/Users/ada/src"), .array([.string("relative/path")]), .array([.number(1)])])
        case .timeRange:
            return ([.object(["start": .string("22:00"), "end": .string("07:30")])],
                    [.object(["start": .string("25:00"), "end": .string("07:00")]), .object(["start": .string("22:00")]),
                     .string("22:00-07:00")])
        case .numberList(let number):
            let low = number.range.lowerBound, high = number.range.upperBound, span = max(high - low, 1)
            return ([.array([]), .array([.number(low), .number(high)])],
                    [.number(low), .array([.number(low - span)]), .array([.number(high + span)]), .array([.string("1")])])
        case .stringMap:
            return ([.object([:]), .object(["*": .string("★"), "Work": .string("")])],
                    [.string("★"), .array([]), .object(["Work": .number(1)])])
        }
    }

    static func numbers(_ number: SettingNumber) -> (accept: [JSONValue], refuse: [JSONValue]) {
        let low = number.range.lowerBound
        let high = number.range.upperBound
        let span = max(high - low, 1)
        return ([.number(low), .number(high), .number(low + (high - low) / 2)],
                [.number(low - span), .number(high + span), .string("1")])
    }
}

/// SHA-256 of the canonical rows JSON, lowercase hex: the daemon reports it
/// so a client can tell that it renders the schema the owner validates.
nonisolated enum SettingsSchemaHash {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
