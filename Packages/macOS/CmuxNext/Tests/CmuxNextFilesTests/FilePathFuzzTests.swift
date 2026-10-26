import CmuxFuzzSupport
import Foundation
import Testing
@testable import CmuxNextFiles

/// Text a person types or pastes into the Files pane (Go to Folder, the filter field, Rename
/// Items) and the names it makes from it: every input gives a value that keeps its contract, never
/// a trap (p10-stability-030). Seeded property tests on CmuxFuzzSupport (long mode:
/// CMUX_FUZZ_SECONDS), the shape of Chromium's url_parse_fuzzer over GURL
/// (url/url_parse_fuzzer.cc): pieces of paths and URLs, joined at random.
struct FilePathFuzzTests {
    static let pieces: [String] = [
        "/", "~", "~/", ".", "..", "./", "../", "//", "\\", "\\ ", "'", "\"", " ", "\t", "\n", "\r\n",
        "file://", "file:///", "file://host/", "file:", "FILE://", "http://x/", "%20", "%2F", "%00", "%", "?q=1", "#f",
        "a", "B", "z9", "007", "10", "2", "18446744073709551616", ".txt", ".tar.gz", ".md", ".app", "copy", "alias",
        "é", "e\u{301}", "ß", "İ", "ﬁ", "Ａ", "中文", "🙂", "\u{0}", "\u{200B}", "\u{202E}", "\u{FFFD}",
    ]
    static let folders = ["/Users/fuzz/work", "/", "/tmp/a b", "/Volumes/Disk/x/y"]
    static let starts = [Int.min, -1, 0, 1, 99_999, 1 << 31, 1 << 32, Int.max - 1, Int.max]

    static func text(_ rng: inout FuzzRNG, _ limit: Int = 12) -> String {
        var out = ""
        for _ in 0..<rng.below(limit) { out += rng.element(of: pieces) ?? "" }
        return out
    }

    static func names(_ rng: inout FuzzRNG, _ limit: Int = 8) -> [String] {
        var out: [String] = []
        for _ in 0..<rng.below(limit) { out.append(text(&rng, 5)) }
        return out
    }

    /// One input of a property its first choice picks (the libFuzzer entry, p10-stability-182).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(6) {
        case 0: try goToFolder(&rng)
        case 1: try freeName(&rng)
        case 2: try batchRename(&rng)
        case 3: try sortKeyOrder(&rng)
        case 4: try nameMatcher(&rng)
        default: try openKind(&rng)
        }
    }

    // MARK: - Properties

    /// Go to Folder: a file URL or nothing, nothing for blank text, and a destination that is the
    /// URL (a folder) or the URL's folder with the URL selected (a file).
    static func goToFolder(_ rng: inout FuzzRNG) throws {
        let typed = text(&rng)
        let current = URL(fileURLWithPath: rng.element(of: folders) ?? "/")
        let exists = !rng.oneIn(4), isFolder = rng.bool()
        let resolver = GoToFolderResolver(home: URL(fileURLWithPath: "/Users/fuzz"), fileExists: { _ in (exists, isFolder) })
        let url = resolver.url(for: typed, relativeTo: current)
        try FuzzRun.check(url?.isFileURL ?? true, "\(typed.debugDescription) gave \(String(describing: url))")
        if typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try FuzzRun.check(url == nil, "blank \(typed.debugDescription) gave \(String(describing: url))")
        }
        let destination = resolver.resolve(typed, relativeTo: current)
        switch (url, destination) {
        case (nil, nil): break
        case (let url?, nil): try FuzzRun.check(!exists, "\(url) exists but resolved to nothing")
        case (nil, _?): try FuzzRun.check(false, "\(typed.debugDescription) has no URL but a destination")
        case let (url?, destination?):
            try FuzzRun.check(exists, "\(url) does not exist but resolved")
            if isFolder {
                try FuzzRun.check(destination.folder == url && destination.select == nil, "folder \(url) gave \(destination)")
            } else {
                try FuzzRun.check(destination.select == url && destination.folder == url.deletingLastPathComponent(),
                                  "file \(url) gave \(destination)")
            }
        }
        let candidates = names(&rng)
        let completions = resolver.completions(for: typed, names: candidates)
        try FuzzRun.check(completions.allSatisfy { candidates.contains($0) }, "completions \(completions) not in \(candidates)")
        try FuzzRun.check(completions.count <= candidates.count, "\(completions.count) completions of \(candidates.count) names")
        try FuzzRun.check(zip(completions, completions.dropFirst()).allSatisfy { pair in !(FileNameSortKey(pair.1) < FileNameSortKey(pair.0)) },
                          "completions out of name order: \(completions)")
    }

    /// Finder's free names: never a taken one; a free name in number style is kept as it is.
    static func freeName(_ rng: inout FuzzRNG) throws {
        let name = text(&rng, 6)
        var taken = Set(names(&rng))
        if rng.bool() { taken.insert(name) }
        // The names the namer tries first, so its counting loop runs.
        let ns = name as NSString
        let stem = ns.pathExtension.isEmpty ? name : ns.deletingPathExtension
        let suffix = ns.pathExtension.isEmpty ? "" : "." + ns.pathExtension
        for n in 2..<(2 + rng.below(6)) {
            taken.insert("\(stem) \(n)\(suffix)")
            taken.insert("\(stem) copy \(n)\(suffix)")
            taken.insert("\(name) alias \(n)")
        }
        let namer = FileNamer(copyWord: rng.element(of: ["copy", "", "Kopie", "🙂"]) ?? "copy",
                              aliasWord: rng.element(of: ["alias", "", "Alias"]) ?? "alias")
        for style in [FileNamer.Style.number, .copy, .alias] {
            let free = namer.freeName(for: name, style: style, taken: taken)
            try FuzzRun.check(!taken.contains(free), "\(style) gave taken \(free.debugDescription) for \(name.debugDescription)")
            if style == .number, !taken.contains(name) {
                try FuzzRun.check(free == name, "free \(name.debugDescription) became \(free.debugDescription)")
            }
        }
        let valid = !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\u{0}")
            && name.utf8.count <= 255
        try FuzzRun.check(namer.isValid(name) == valid, "isValid(\(name.debugDescription)) is \(!valid)")
    }

    /// Rename Items: one item per name in order, and each problem is the one its name has.
    static func batchRename(_ rng: inout FuzzRNG) throws {
        let position: BatchRename.Position = rng.bool() ? .beforeName : .afterName
        let rule: BatchRename.Rule = switch rng.below(3) {
        case 0: .replace(find: text(&rng, 3), with: text(&rng, 3), caseSensitive: rng.bool())
        case 1: .add(text: text(&rng, 3), position: position)
        default:
            .format(base: text(&rng, 3), style: rng.element(of: [BatchRename.FormatStyle.index, .counter, .date]) ?? .index, position: position,
                    start: rng.oneIn(2) ? rng.element(of: starts) ?? 0 : rng.int(in: Int.min...Int.max))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let rename = BatchRename(rule: rule, now: Date(timeIntervalSince1970: 1_792_000_000), calendar: calendar)
        let items = rename.plan(names(&rng), taken: Set(names(&rng)))
        let namer = FileNamer()
        for (index, item) in items.enumerated() {
            let earlier = items[..<index].contains { $0.to == item.to }
            switch item.problem {
            case nil:
                try FuzzRun.check(namer.isValid(item.to) && !earlier, "\(item) has a problem it does not name")
            case .duplicate?:
                try FuzzRun.check(earlier, "\(item) is no duplicate")
            case .invalid?, .exists?:
                break
            }
        }
    }

    /// Finder's name order: the key comparison is a total order (antisymmetric, transitive, zero
    /// only for equal keys).
    static func sortKeyOrder(_ rng: inout FuzzRNG) throws {
        let keys = (text(&rng, 6), text(&rng, 6), text(&rng, 6))
        let (a, b, c) = (FileNameSortKey(keys.0), FileNameSortKey(keys.1), FileNameSortKey(keys.2))
        try FuzzRun.check(a.compare(b).signum() == -b.compare(a).signum(), "\(keys.0) and \(keys.1) are not antisymmetric")
        try FuzzRun.check((a.compare(b) == 0) == (a == b), "\(keys.0) and \(keys.1) compare 0 but differ")
        if a < b, b < c { try FuzzRun.check(a < c, "\(keys) are not transitive") }
        if a == b { try FuzzRun.check(a.hashValue == b.hashValue, "equal keys hash apart") }
    }

    /// The filter field: an ASCII needle in an ASCII name matches as a case-blind byte search;
    /// empty text matches every name.
    static func nameMatcher(_ rng: inout FuzzRNG) throws {
        let needle = text(&rng, 3), name = text(&rng, 8)
        let matcher = FileNameMatcher(needle)
        let matches = matcher.matches(name)
        if needle.isEmpty { try FuzzRun.check(matches && matcher.matchesAll, "empty text missed \(name.debugDescription)") }
        guard needle.utf8.allSatisfy({ $0 < 0x80 }), name.utf8.allSatisfy({ $0 < 0x80 }) else { return }
        let lower = { (byte: UInt8) in (0x41...0x5A).contains(byte) ? byte + 0x20 : byte }
        let hay = name.utf8.map(lower), sought = needle.utf8.map(lower)
        let expected = sought.isEmpty || (sought.count <= hay.count
            && (0...(hay.count - sought.count)).contains { Array(hay[$0..<($0 + sought.count)]) == sought })
        try FuzzRun.check(matches == expected, "\(needle.debugDescription) in \(name.debugDescription) is \(matches)")
    }

    /// The open rule: any name gives a kind; a plain folder is a folder, an app bundle an app.
    static func openKind(_ rng: inout FuzzRNG) throws {
        let name = text(&rng, 6)
        let isDirectory = rng.bool(), isPackage = rng.bool()
        let kind = FileOpenKind(fileName: name, isDirectory: isDirectory, isPackage: isPackage)
        guard isDirectory else { return }
        let bundle = isPackage || FileOpenKind.packageExtensions.contains((name as NSString).pathExtension.lowercased())
        try FuzzRun.check(kind == (bundle ? .app : .folder), "directory \(name.debugDescription) is \(kind)")
    }

    // MARK: - Runs

    @Test func goToFolderGivesAFileURLOrNothing() throws {
        try FuzzRun("FilePath.goToFolder", seed: 0x60_70F0, iterations: 4_000).forEach { rng in try Self.goToFolder(&rng) }
    }

    @Test func freeNamesAreNeverTaken() throws {
        try FuzzRun("FilePath.freeName", seed: 0xF4EE, iterations: 3_000).forEach { rng in try Self.freeName(&rng) }
    }

    @Test func batchRenameNamesEachProblem() throws {
        try FuzzRun("FilePath.batchRename", seed: 0xBA7C, iterations: 3_000).forEach { rng in try Self.batchRename(&rng) }
    }

    @Test func sortKeysAreATotalOrder() throws {
        try FuzzRun("FilePath.sortKey", seed: 0x5027, iterations: 5_000).forEach { rng in try Self.sortKeyOrder(&rng) }
    }

    @Test func asciiFilterIsACaseBlindByteSearch() throws {
        try FuzzRun("FilePath.matcher", seed: 0x3A7C, iterations: 5_000).forEach { rng in try Self.nameMatcher(&rng) }
    }

    @Test func everyNameHasAnOpenKind() throws {
        try FuzzRun("FilePath.openKind", seed: 0x0BE4, iterations: 2_000).forEach { rng in try Self.openKind(&rng) }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("FilePath.oneInput", seed: 0xF11E, iterations: 1_024)
        // Choice tapes: a first byte picks the property, then piece counts and indices.
        let tapes: [[UInt8]] = [[0], [1, 3, 0, 22], [2, 2, 3, 1], [3, 2, 25, 26], [4, 1, 21], [5, 2, 0, 1]]
        try run.forEachInput(run.corpus(seeds: tapes.map { Data($0) })) { try Self.oneInput($0) }
    }

    /// Found by `batchRenameNamesEachProblem`: a start number near `Int.max` made the next item's
    /// number overflow and trap, and Counter printed only an `Int`'s low 32 bits.
    @Test func hugeStartNumberIsInvalidNotATrap() {
        let index = BatchRename(rule: .format(base: "Trip", style: .index, position: .afterName, start: Int.max))
            .plan(["a.jpg", "b.jpg"], taken: [])
        #expect(index.map(\.to) == ["Trip 9223372036854775807.jpg", "b.jpg"])
        #expect(index.map(\.problem) == [nil, .invalid])
        let counter = BatchRename(rule: .format(base: "Trip", style: .counter, position: .afterName, start: 1 << 32))
            .plan(["a.jpg", "b.jpg"], taken: [])
        #expect(counter.map(\.to) == ["Trip 4294967296.jpg", "Trip 4294967297.jpg"])
        let small = BatchRename(rule: .format(base: "Trip", style: .counter, position: .beforeName, start: 7)).plan(["a"], taken: [])
        #expect(small.map(\.to) == ["00007 Trip"])
    }
}
