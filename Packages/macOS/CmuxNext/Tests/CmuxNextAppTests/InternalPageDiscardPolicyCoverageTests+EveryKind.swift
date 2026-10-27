@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextMemory
import CmuxNextWakeups
import Foundation
import Testing

extension InternalPageDiscardPolicyCoverageTests {
    /// p07-memory-029 (p07-memory.md DC4; queues MQ-PAGES, MQ-CONTENT, MQ-BROWSERTAB): every kind of
    /// content a tab shows says when its hidden copy may go, so the `memoryDiscard*` features can
    /// release all a person cannot see. Chrome decides every tab's discard eligibility in one place
    /// (chrome/browser/performance_manager/policies/discard_eligibility_policy.cc); cmux's kinds
    /// declare theirs in code, and this suite fails for one that does not:
    /// - an internal page provider that neither implements `discardPolicy(for:)` nor says
    ///   `// discard: default <why>`. Every `InternalPageID` shows through a provider (the page store
    ///   keeps one per page), so this covers every page. A `WebPageTab(...)` call without a policy
    ///   argument takes WebPageTab's default and needs the same comment;
    /// - a `TabContent` case whose class's ``TabContentClass/discard`` names a ``ContentKind`` with no discard path;
    /// - a `BrowserTab` other than the mock, hibernated and deferred tabs that is not a
    ///   `BrowserHibernationSource` and does not say `// discard: never <why>`.
    ///
    /// A conformance through a refining protocol counts: `extension HistoryPageTab: BrowserAppPage`
    /// where `protocol BrowserAppPage: BrowserHibernationSource`.
    @Suite struct EveryKind {
        /// The `BrowserTab`s that are never discarded by design: the test engine's tab, the
        /// hibernated tab (the discarded form itself) and the deferred tab (nothing loaded yet).
        static let browserTabsWithoutDiscard: Set<String> = ["MockBrowserTab", "HibernatedBrowserTab", "DeferredBrowserTab"]

        /// The package's `Sources`.
        static var sources: URL { InternalPageDiscardPolicyCoverageTests.packageRoot.appendingPathComponent("Sources") }

        /// The sources, read once for the suite.
        static let corpus = DiscardCoverageScan.loading(sources)

        private static func scanned() throws -> DiscardCoverageScan {
            let corpus = Self.corpus
            try #require(corpus.loadError == nil, "\(corpus.loadError ?? "")")
            try #require(corpus.fileCount > 100, "read only \(corpus.fileCount) Swift files under \(sources.path)")
            return corpus
        }

        // MARK: Internal pages (MQ-PAGES)

        @Test func everyInternalPageProviderDeclaresItsDiscardPolicy() throws {
            let corpus = try Self.scanned()
            let providers = corpus.conformers(to: "InternalPageProvider")
            let names = Set(providers.map(\.name))
            #expect(names.isSuperset(of: ["DebugHomeNativeFixture", "WebPageTab", "SettingsWindowService", "AppsService", "AppPanePage"]),
                    "the scan finds the page providers; it found \(names.sorted())")
            let missing = providers.filter { !corpus.declaresPagePolicy($0.name) }.map { "\($0.file):\($0.line): \($0.name)" }
            #expect(missing.isEmpty, """
            These internal pages are on the default policy (never discarded) without saying why. \
            Implement discardPolicy(for:) (with keepReasons, saveViewState and viewDiscarded as the \
            page needs), or write `// discard: default <why>` on the provider:
            \(missing.joined(separator: "\n"))
            """)
        }

        @Test func everyWebPageTabIsMadeWithAPolicy() throws {
            let corpus = try Self.scanned()
            try #require(corpus.webPageTabCalls.count >= 4, "the scan finds the WebPageTab pages (Stats, Chief Usage, CodeRouter)")
            let missing = corpus.webPageTabCalls.filter { !$0.passesPolicy && !corpus.chunk($0.chunk, has: "default") }
                .map { "\($0.file):\($0.line)" }
            #expect(missing.isEmpty, """
            These WebPageTab pages take WebPageTab's default policy without choosing it. Pass the \
            page's own policy, or write `// discard: default <why>` beside the call:
            \(missing.joined(separator: "\n"))
            """)
        }

        /// Two ids with one raw value are one page to the store (it keeps one provider per page): the
        /// second provider, and its policy, would replace the first.
        @Test func everyInternalPageIDNamesItsOwnPage() throws {
            let corpus = try Self.scanned()
            #expect(corpus.pageIDs.contains { $0.rawValue == "home-native-fixture" }, "the scan finds the page ids (MQ-PAGES)")
            let literal = corpus.pageIDs.filter { $0.rawValue != nil }
            let shared = Dictionary(grouping: literal) { $0.rawValue ?? "" }.filter { $0.value.count > 1 }
                .map { raw, ids in "\(raw): " + ids.map { "\($0.file):\($0.line) \($0.name)" }.joined(separator: ", ") }
            #expect(shared.isEmpty, "page ids share a raw value:\n\(shared.sorted().joined(separator: "\n"))")
        }

        #if DEBUG || CMUX_BENCH_HOOKS
        @MainActor @Test func theHomeFixtureIsNeverDiscarded() {
            let fixture = DebugHomeNativeFixture(openPanel: MadeAheadOpenPanel(), mainWork: linklessMainWork(), work: BackgroundWork(label: "test.home-fixture"))
            #expect(fixture.discardPolicy(for: LocalPageTab.makeKey(.homeNativeFixture)) == .never)
        }
        #endif

        // MARK: Tab content (MQ-CONTENT)

        /// `TabContent.contentClass` and `TabContentClass.discard` are exhaustive switches, so the compiler asks for a row for a new
        /// case; this checks that each claimed kind has a discard path: the browser or agent page
        /// hibernation (``MemoryHistograms/hibernationKinds``) or a `ContentDiscardScheduler` of that kind.
        @Test func everyTabContentKindHasADiscardPath() throws {
            let corpus = try Self.scanned()
            let cases = TabContentClass.allCases
            #expect(cases.count >= 7, "TabContent has 7 cases (MQ-CONTENT); TabContentClass lists \(cases)")
            let hibernated = Set(MemoryHistograms.hibernationKinds)
            for content in cases {
                switch content.discard {
                case .kind(let kind):
                    let scheduler = "ContentDiscardScheduler(kind: .\(kind)"
                    let scheduled = corpus.chunks.contains { $0.code.contains(scheduler) }
                    #expect(hibernated.contains(kind.rawValue) || scheduled, """
                    TabContent.\(content) claims ContentKind.\(kind), but nothing discards that kind: no \
                    hibernation records it and no `\(scheduler))` is built. Give the kind a discard path, \
                    or declare the class `.never(why:)` in CmuxNextHibernation/TabContentClass.swift.
                    """)
                case .warmSet:
                    #expect(content == .terminal, "the warm set holds terminals only; TabContent.\(content) is not one")
                case .never(let why):
                    #expect(why.split(whereSeparator: \.isWhitespace).count >= 3, "TabContent.\(content) is never discarded without why")
                }
            }
        }

        // MARK: Browser tabs (MQ-BROWSERTAB)

        @Test func everyBrowserTabCanBeDiscardedOrSaysWhyNot() throws {
            let corpus = try Self.scanned()
            let tabs = corpus.conformers(to: "BrowserTab")
            let names = Set(tabs.map(\.name))
            #expect(names.isSuperset(of: Self.browserTabsWithoutDiscard.union(["WebKitTab", "CEFTab"])),
                    "the scan finds the browser tabs; it found \(names.sorted())")
            let missing = tabs.filter { !Self.browserTabsWithoutDiscard.contains($0.name) && !corpus.hibernates($0.name) }
                .map { "\($0.file):\($0.line): \($0.name)" }
            #expect(missing.isEmpty, """
            These browser tabs keep their page while hidden at any pressure. Make the tab a \
            BrowserHibernationSource (CmuxNextBrowser/Engine/BrowserHibernationSupport.swift), or write \
            `// discard: never <why>` on it:
            \(missing.joined(separator: "\n"))
            """)
        }

        // MARK: The scanner

        @Test func theScanReadsDeclarationsExtensionsRefinementsAndMarkers() {
            let source = """
            import AppKit

            /// A page.
            // discard: default the page shows one fixed line
            @MainActor
            final class Marked: InternalPageProvider {
                var page: InternalPageID { .settings }
            }

            @MainActor
            final class Declared: NSObject, InternalPageProvider {}

            extension Declared {
                func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }
            }

            final class Commented: InternalPageProvider {
                // func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }
            }

            final class Silent: InternalPageProvider {
                // discard: default
            }

            enum Outer {
                final class Inner: BrowserTab {} // discard: never a test tab that holds nothing
            }

            public final class Live: BrowserTab, BrowserOcclusionHosting {}
            extension Live: BrowserHibernationSource {}

            final class Bare: BrowserTab {}
            protocol Refined: BrowserTab {}
            protocol Deeper: Refined {}
            final class ViaRefined: Deeper {}
            protocol Sleeps: BrowserHibernationSource {}
            final class Sleepy: BrowserTab {}
            extension Sleepy: Sleeps {}
            protocol Page: InternalPageProvider {}
            final class Paged: Page {}

            let a = WebPageTab(.stats, symbol: "s", title: t,
                               discardPolicy: .standard) { nil }
            let b = WebPageTab(.chiefUsage, symbol: "s", title: t) { nil }
            // let c = WebPageTab(.stats, symbol: "s", title: t) { nil }
            """
            var corpus = DiscardCoverageScan()
            corpus.add(source, file: "Fixture.swift")

            let pages = corpus.conformers(to: "InternalPageProvider")
            #expect(pages.map(\.name) == ["Marked", "Declared", "Commented", "Silent", "Paged"])
            #expect(pages.map { corpus.declaresPagePolicy($0.name) } == [true, true, false, false, false])
            #expect(pages.first?.line == 6)

            let tabs = corpus.conformers(to: "BrowserTab")
            #expect(tabs.map(\.name) == ["Inner", "Live", "Bare", "ViaRefined", "Sleepy"])
            #expect(tabs.map { corpus.hibernates($0.name) } == [true, true, false, false, true])

            #expect(corpus.webPageTabCalls.map(\.line) == [42, 44])
            #expect(corpus.webPageTabCalls.map(\.passesPolicy) == [true, false])
        }

        /// A provider may declare its policy in an extension in another file, one that names none of
        /// the protocols.
        @Test func theScanReadsEveryFileSoAPolicyInAnotherFileCounts() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "discard-coverage-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appending(path: "Pages"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try "final class Tasks: InternalPageProvider {}\n".write(to: root.appending(path: "Tasks.swift"), atomically: true, encoding: .utf8)
            try """
            extension Tasks {
                func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }
            }
            """.write(to: root.appending(path: "Pages/Tasks+Discard.swift"), atomically: true, encoding: .utf8)

            let corpus = DiscardCoverageScan.loading(root)
            #expect(corpus.loadError == nil)
            #expect(corpus.fileCount == 2)
            #expect(corpus.conformers(to: "InternalPageProvider").map(\.name) == ["Tasks"])
            #expect(corpus.declaresPagePolicy("Tasks"))
        }
    }
}

/// The package's Swift sources as a coverage rule reads them: type declarations with their
/// conformances, each top-level declaration's text (the comment and attribute lines right above
/// it through the line before the next one), the page ids and the `WebPageTab(...)` calls.
struct DiscardCoverageScan: Sendable {
    struct TypeDeclaration: Sendable {
        let file: String
        let line: Int
        let keyword: String
        let name: String
        let inherits: [String]
        /// The top-level declaration it is or sits in, an index into ``chunks``.
        let chunk: Int
    }

    struct Chunk: Sendable {
        /// Every line.
        let text: String
        /// The lines that are not comments.
        let code: String
    }

    struct PageIDDeclaration: Sendable {
        let file: String
        let line: Int
        let name: String
        /// The literal raw value, nil when it is computed.
        let rawValue: String?
    }

    struct WebPageTabCall: Sendable {
        let file: String
        let line: Int
        let chunk: Int
        /// The call passes a policy argument (`discardPolicy:`, `hiddenPolicy:`).
        let passesPolicy: Bool
    }

    static let typeKeywords: Set<String> = ["class", "struct", "enum", "actor", "extension", "protocol"]
    static let modifiers: Set<String> = ["public", "package", "internal", "private", "fileprivate", "final", "open",
                                         "nonisolated", "indirect"]

    var fileCount = 0
    var loadError: String?
    var types: [TypeDeclaration] = []
    var chunks: [Chunk] = []
    var pageIDs: [PageIDDeclaration] = []
    var webPageTabCalls: [WebPageTabCall] = []

    /// Reads and parses every Swift file under `root`; a failure is kept in ``loadError``.
    static func loading(_ root: URL) -> DiscardCoverageScan {
        var corpus = DiscardCoverageScan()
        let path = root.standardizedFileURL.path
        guard let files = FileManager.default.enumerator(atPath: path) else {
            corpus.loadError = "cannot list \(path)"
            return corpus
        }
        do {
            while let relative = files.nextObject() as? String {
                guard relative.hasSuffix(".swift") else { continue }
                let text = try String(contentsOfFile: path + "/" + relative, encoding: .utf8)
                corpus.fileCount += 1
                corpus.add(text, file: relative)
            }
        } catch {
            corpus.loadError = "\(error)"
        }
        return corpus
    }

    /// `root` and every protocol that refines it, directly or through another.
    func refinements(of root: String) -> Set<String> {
        let protocols = types.filter { $0.keyword == "protocol" }
        var names: Set<String> = [root]
        var grew = true
        while grew {
            grew = false
            for declaration in protocols where !names.contains(declaration.name) && declaration.inherits.contains(where: { names.contains($0) }) {
                names.insert(declaration.name)
                grew = true
            }
        }
        return names
    }

    /// The types that list `protocolName`, or a protocol that refines it, among their conformances
    /// (on the type or on an extension), first declaration first; a protocol is not one.
    func conformers(to protocolName: String) -> [TypeDeclaration] {
        let accepted = refinements(of: protocolName)
        var seen: Set<String> = []
        return types.filter {
            $0.keyword != "protocol" && $0.inherits.contains(where: accepted.contains) && seen.insert($0.name).inserted
        }
    }

    /// Whether type `name` implements `discardPolicy(for:)` or says `// discard: default <why>`.
    func declaresPagePolicy(_ name: String) -> Bool {
        chunkIndices(of: name).contains { chunks[$0].code.contains("func discardPolicy(for ") || chunk($0, has: "default") }
    }

    /// Whether browser tab `name` is a `BrowserHibernationSource` (itself or through a refining
    /// protocol) or says `// discard: never <why>`.
    func hibernates(_ name: String) -> Bool {
        let sources = refinements(of: "BrowserHibernationSource")
        return types.contains { $0.name == name && $0.keyword != "protocol" && $0.inherits.contains(where: sources.contains) }
            || chunkIndices(of: name).contains { chunk($0, has: "never") }
    }

    /// Whether chunk `index` has a `// discard: <kind> <why>` line, the why at least two words.
    func chunk(_ index: Int, has kind: String) -> Bool {
        chunks[index].text.split(separator: "\n").contains { line in
            guard let marker = line.range(of: "// discard: ") else { return false }
            let words = line[marker.upperBound...].split(whereSeparator: \.isWhitespace)
            guard let first = words.first else { return false }
            return first == kind && words.count >= 3
        }
    }

    /// The chunks of type `name`'s declarations and extensions.
    private func chunkIndices(of name: String) -> Set<Int> {
        Set(types.filter { $0.name == name && $0.keyword != "protocol" }.map(\.chunk))
    }

    /// Parses one file.
    mutating func add(_ text: String, file: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var headers: [(line: Int, keyword: String, name: String, inherits: [String])] = []
        var topLevel: [Int] = []
        for (index, line) in lines.enumerated() {
            guard let header = Self.typeHeader(line) else { continue }
            headers.append((index, header.keyword, header.name, header.inherits))
            if line.first.map({ !$0.isWhitespace }) ?? false { topLevel.append(index) }
        }

        // A top-level declaration's chunk starts at the comment and attribute lines right above its
        // header and ends where the next one's starts; the lines before the first are a chunk too.
        var bounds = [0]
        var floor = 0
        for header in topLevel {
            var start = header
            while start > floor, lines[start - 1].hasPrefix("//") || lines[start - 1].hasPrefix("@") { start -= 1 }
            bounds.append(start)
            floor = header + 1
        }
        bounds.append(lines.count)
        let base = chunks.count
        for index in 0..<(bounds.count - 1) {
            let slice = lines[bounds[index]..<bounds[index + 1]]
            let code = slice.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            chunks.append(Chunk(text: slice.joined(separator: "\n"), code: code.joined(separator: "\n")))
        }
        // The last chunk whose start is at or before `line` (bounds.last is past every line).
        func chunkIndex(containing line: Int) -> Int { base + (bounds.lastIndex { $0 <= line } ?? 0) }

        for header in headers {
            types.append(TypeDeclaration(file: file, line: header.line + 1, keyword: header.keyword, name: header.name,
                                         inherits: header.inherits, chunk: chunkIndex(containing: header.line)))
        }
        for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            if let id = Self.pageID(line) {
                pageIDs.append(PageIDDeclaration(file: file, line: index + 1, name: id.name, rawValue: id.rawValue))
            }
            if let arguments = Self.webPageTabArguments(lines, at: index) {
                webPageTabCalls.append(WebPageTabCall(file: file, line: index + 1, chunk: chunkIndex(containing: index),
                                                      passesPolicy: arguments.contains("olicy:")))
            }
        }
    }

    /// `[@Attr ...] [modifiers] class|struct|enum|actor|extension|protocol Name[<...>][: A, B] {`.
    static func typeHeader(_ line: String) -> (keyword: String, name: String, inherits: [String])? {
        let words = line.split(whereSeparator: \.isWhitespace)
        var index = 0
        while index < words.count, words[index].hasPrefix("@") || modifiers.contains(String(words[index])) { index += 1 }
        guard index + 1 < words.count, typeKeywords.contains(String(words[index])) else { return nil }
        let keyword = String(words[index])
        let declared = words[index + 1]
        let nameEnd = declared.firstIndex(where: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }) ?? declared.endIndex
        let qualified = declared[..<nameEnd]
        guard let first = qualified.first, first.isLetter || first == "_" else { return nil }
        let name = String(qualified.split(separator: ".").last ?? qualified)
        // The text after the name, through the line's end.
        guard let keywordRange = line.range(of: keyword + " "),
              let nameRange = line.range(of: String(qualified), range: keywordRange.upperBound..<line.endIndex) else { return nil }
        return (keyword, name, inherits(String(line[nameRange.upperBound...])))
    }

    /// The conformance list after a type's name: `<T>: A, @unchecked B<T> where ... {` gives A and B.
    static func inherits(_ rest: String) -> [String] {
        var text = Substring(rest)
        if text.hasPrefix("<") {
            var depth = 0
            let close = text.firstIndex { character in
                if character == "<" { depth += 1 }
                if character == ">" { depth -= 1 }
                return depth == 0
            }
            guard let close else { return [] }
            text = text[text.index(after: close)...]
        }
        text = text.drop { $0 == " " }
        guard text.hasPrefix(":") else { return [] }
        text = text.dropFirst()
        if let open = text.firstIndex(of: "{") { text = text[..<open] }
        if let clause = text.range(of: " where ") { text = text[..<clause.lowerBound] }
        return text.split(separator: ",").compactMap { entry in
            let words = entry.split(whereSeparator: \.isWhitespace).filter { !$0.hasPrefix("@") }
            guard let type = words.first else { return nil }
            return String(type.prefix { $0 != "<" })
        }
    }

    /// `static let <name> = InternalPageID(rawValue: "<raw>")`; the raw value is nil when computed.
    static func pageID(_ line: String) -> (name: String, rawValue: String?)? {
        guard let call = line.range(of: "InternalPageID("), let decl = line.range(of: "static let "),
              decl.upperBound <= call.lowerBound else { return nil }
        let between = line[decl.upperBound..<call.lowerBound]
        guard let equals = between.firstIndex(of: "=") else { return nil }
        let name = between[..<equals].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        let argument = line[call.upperBound...].drop { $0 == " " }
        guard argument.hasPrefix("rawValue: \"") else { return (name, nil) }
        let literal = argument.dropFirst("rawValue: \"".count)
        guard let quote = literal.firstIndex(of: "\"") else { return (name, nil) }
        return (name, String(literal[..<quote]))
    }

    /// The argument text of a `WebPageTab(` call that starts on `lines[index]`, through its
    /// closing parenthesis (it may span up to 20 lines); nil when the line makes none.
    static func webPageTabArguments(_ lines: [String], at index: Int) -> String? {
        let line = lines[index]
        guard let call = line.range(of: "WebPageTab(") else { return nil }
        if call.lowerBound > line.startIndex {
            let before = line[line.index(before: call.lowerBound)]
            if before.isLetter || before.isNumber || before == "_" { return nil }
        }
        var depth = 1
        var arguments = ""
        var text = Substring(line[call.upperBound...])
        var next = index + 1
        while true {
            for character in text {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if depth == 0 { return arguments }
                arguments.append(character)
            }
            guard next < lines.count, next - index < 20 else { return arguments }
            arguments.append("\n")
            text = Substring(lines[next])
            next += 1
        }
    }
}
