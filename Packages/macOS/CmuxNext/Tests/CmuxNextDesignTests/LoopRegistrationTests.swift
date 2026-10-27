import Foundation
import Testing

/// Every infinite Core Animation loop in CmuxNext's sources runs through a ``LoopHost``
/// (p14-energy-056): a loop added with a bare `layer.add` keeps the render server drawing frames
/// for a hidden view or an occluded window. A source check, as `rg 'repeatCount = .infinity'`.
struct LoopRegistrationTests {
    /// The files whose infinite loops are factories: each factory's callers attach what it makes.
    private static let factoryFiles: Set<String> = ["Motion+AppKit.swift", "Motion+Wiggle.swift"]
    /// How many infinite loops CmuxNext has (plans/cmux-next/chrome-parity/p14-energy.md): a new one
    /// registers with a ``LoopHost`` and raises this count.
    private static let expectedSites = 10

    private struct Source {
        let url: URL
        let lines: [String]
        var name: String { url.lastPathComponent }
        var code: [(number: Int, text: String)] {
            lines.enumerated().compactMap { index, line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? nil : (index + 1, line)
            }
        }
    }

    @Test func everyInfiniteLoopRegistersWithALoopHost() throws {
        let sources = try Self.sources()
        var sites: [String] = []
        var factories: Set<String> = []
        var unregistered: [String] = []
        for source in sources {
            for (number, text) in source.code where text.contains("repeatCount = .infinity") {
                let site = "\(source.name):\(number)"
                sites.append(site)
                if Self.factoryFiles.contains(source.name) {
                    let factory = try #require(Self.enclosingFunction(in: source.lines, before: number), "no func above \(site)")
                    factories.insert(factory)
                } else if !Self.registers(source, in: sources) {
                    unregistered.append(site)
                }
            }
        }
        #expect(sites.count == Self.expectedSites, "infinite loops in CmuxNext: \(sites)")
        #expect(factories.isSuperset(of: ["spinAnimation", "pulseAnimation", "wiggleAnimation"]), "factories: \(factories)")

        for factory in factories.sorted() {
            for source in sources where !Self.factoryFiles.contains(source.name) {
                for (number, text) in source.code where text.contains(".\(factory)(") && !Self.registers(source, in: sources) {
                    unregistered.append("\(source.name):\(number) (\(factory))")
                }
            }
        }
        #expect(unregistered.isEmpty, "infinite loops added outside a LoopHost: \(unregistered)")
    }

    /// A file registers its loops when it, or the file of the type it extends (`Row+Editing.swift`
    /// extends `Row.swift`), goes through ``LoopVisibility``.
    private static func registers(_ source: Source, in sources: [Source]) -> Bool {
        func usesLoopVisibility(_ source: Source) -> Bool {
            source.code.contains { $0.text.contains("LoopVisibility(") || $0.text.contains("LoopVisibility.add(") }
        }
        if usesLoopVisibility(source) { return true }
        guard let plus = source.name.firstIndex(of: "+") else { return false }
        let base = source.url.deletingLastPathComponent().appendingPathComponent(String(source.name[..<plus]) + ".swift")
        return sources.contains { $0.url.standardizedFileURL == base.standardizedFileURL && usesLoopVisibility($0) }
    }

    /// The public function a site sits in (a nested helper such as the wiggle's `turn` is skipped).
    private static func enclosingFunction(in lines: [String], before number: Int) -> String? {
        for line in lines[..<number].reversed() {
            guard let range = line.range(of: "public func ") else { continue }
            return String(line[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        }
        return nil
    }

    private static func sources() throws -> [Source] {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/CmuxNextDesign").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no Sources/CmuxNextDesign above \(#filePath)")
            root = parent
        }
        let sourcesRoot = root.appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        return try walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map { url in
            Source(url: url, lines: try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n"))
        }
    }
}
