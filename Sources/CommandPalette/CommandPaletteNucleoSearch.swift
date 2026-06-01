import Darwin
import Foundation

struct CommandPaletteNucleoSearchResult<Payload>: Sendable where Payload: Sendable {
    let payload: Payload
    let rank: Int
    let title: String
    let score: Int
    let titleMatchIndices: Set<Int>
}

// Sendable is safe here because the dlopen handle and C function pointers are
// immutable after initialization. The Rust side owns synchronization for index
// search state.
final class CommandPaletteNucleoSearchLibrary: @unchecked Sendable {
    private typealias CreateIndex = @convention(c) (
        UnsafePointer<UInt8>?,
        Int,
        UnsafeRawPointer?,
        Int
    ) -> OpaquePointer?
    private typealias DestroyIndex = @convention(c) (OpaquePointer?) -> Void
    private typealias SearchIndexWithBoosts = @convention(c) (
        OpaquePointer?,
        UnsafePointer<UInt8>?,
        Int,
        Int,
        UnsafePointer<Int32>?,
        Int,
        UnsafeMutableRawPointer?,
        Int,
        UnsafeMutablePointer<Int>?
    ) -> Int32
    private typealias Version = @convention(c) () -> UInt32

    private static let supportedVersion: UInt32 = 2
    static let shared = CommandPaletteNucleoSearchLibrary.loadDefault()

    private let handle: UnsafeMutableRawPointer
    private let createIndex: CreateIndex
    private let destroyIndex: DestroyIndex
    private let searchIndexWithBoosts: SearchIndexWithBoosts
    let version: UInt32

    private init(
        handle: UnsafeMutableRawPointer,
        createIndex: @escaping CreateIndex,
        destroyIndex: @escaping DestroyIndex,
        searchIndexWithBoosts: @escaping SearchIndexWithBoosts,
        version: UInt32
    ) {
        self.handle = handle
        self.createIndex = createIndex
        self.destroyIndex = destroyIndex
        self.searchIndexWithBoosts = searchIndexWithBoosts
        self.version = version
    }

    deinit {
        dlclose(handle)
    }

    static func loadDefault() -> CommandPaletteNucleoSearchLibrary? {
        for path in defaultLibraryPaths() where FileManager.default.fileExists(atPath: path) {
            if let library = load(path: path) {
                return library
            }
        }
        return nil
    }

    private static func load(path: String) -> CommandPaletteNucleoSearchLibrary? {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }

        guard let createIndex = symbol("cmux_nucleo_index_create", from: handle, as: CreateIndex.self),
              let destroyIndex = symbol("cmux_nucleo_index_destroy", from: handle, as: DestroyIndex.self),
              let searchIndexWithBoosts = symbol(
                "cmux_nucleo_index_search_with_boosts",
                from: handle,
                as: SearchIndexWithBoosts.self
              ),
              let version = symbol("cmux_nucleo_ffi_version", from: handle, as: Version.self) else {
            dlclose(handle)
            return nil
        }
        let resolvedVersion = version()
        guard resolvedVersion == supportedVersion else {
            dlclose(handle)
            return nil
        }

        CommandPaletteNucleoABI.assertCompatibleLayout()

        return CommandPaletteNucleoSearchLibrary(
            handle: handle,
            createIndex: createIndex,
            destroyIndex: destroyIndex,
            searchIndexWithBoosts: searchIndexWithBoosts,
            version: resolvedVersion
        )
    }

    private static func symbol<T>(_ name: String, from handle: UnsafeMutableRawPointer, as _: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static func defaultLibraryPaths() -> [String] {
        var paths: [String] = []
        let environmentPath = ProcessInfo.processInfo.environment["CMUX_NUCLEO_FFI_LIB"]
        if let environmentPath, !environmentPath.isEmpty {
            paths.append(environmentPath)
        }

        if let privateFrameworksPath = Bundle.main.privateFrameworksPath {
            paths.append(
                URL(fileURLWithPath: privateFrameworksPath)
                    .appendingPathComponent(Self.libraryFileName)
                    .path
            )
        }

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        paths.append(
            sourceRoot
                .appendingPathComponent("Native/CommandPaletteNucleoFFI/target/cmux-nucleo-ffi")
                .appendingPathComponent(Self.libraryFileName)
                .path
        )
        paths.append(
            sourceRoot
                .appendingPathComponent("Native/CommandPaletteNucleoFFI/target/release")
                .appendingPathComponent(Self.libraryFileName)
                .path
        )
        paths.append(
            sourceRoot
                .appendingPathComponent("Native/CommandPaletteNucleoFFI/target/aarch64-apple-darwin/release")
                .appendingPathComponent(Self.libraryFileName)
                .path
        )
        paths.append(
            sourceRoot
                .appendingPathComponent("Native/CommandPaletteNucleoFFI/target/x86_64-apple-darwin/release")
                .appendingPathComponent(Self.libraryFileName)
                .path
        )

        return paths
    }

    private static let libraryFileName = "libcmux_command_palette_nucleo_ffi.dylib"

    func createIndex<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>]
    ) -> OpaquePointer? {
        var blob: [UInt8] = []
        var spans: [CommandPaletteNucleoCandidateSpan] = []
        blob.reserveCapacity(entries.reduce(0) { total, entry in
            total + entry.title.utf8.count + entry.nucleoSearchText.utf8.count
        })
        spans.reserveCapacity(entries.count)

        for entry in entries {
            let titleOffset = blob.count
            blob.append(contentsOf: entry.title.utf8)
            let titleLength = blob.count - titleOffset

            let searchOffset = blob.count
            blob.append(contentsOf: entry.nucleoSearchText.utf8)
            let searchLength = blob.count - searchOffset

            spans.append(
                CommandPaletteNucleoCandidateSpan(
                    titleOffset: titleOffset,
                    titleLength: titleLength,
                    searchOffset: searchOffset,
                    searchLength: searchLength,
                    rank: Int32(clamping: entry.rank)
                )
            )
        }

        return blob.withUnsafeBufferPointer { blobBuffer in
            spans.withUnsafeBufferPointer { spanBuffer in
                createIndex(
                    blobBuffer.baseAddress,
                    blobBuffer.count,
                    UnsafeRawPointer(spanBuffer.baseAddress),
                    spanBuffer.count
                )
            }
        }
    }

    func destroy(index: OpaquePointer?) {
        destroyIndex(index)
    }

    fileprivate func search(
        index: OpaquePointer,
        query: String,
        resultLimit: Int,
        boosts: [Int32]?
    ) -> [CommandPaletteNucleoRawMatch]? {
        guard resultLimit > 0 else { return [] }

        var matches = Array(
            repeating: CommandPaletteNucleoRawMatch(index: 0, score: 0, rank: 0),
            count: max(1, resultLimit)
        )
        var count = 0
        let queryBytes = Array(query.utf8)
        let boostsCount = boosts?.count ?? 0
        let status = queryBytes.withUnsafeBufferPointer { queryBuffer in
            matches.withUnsafeMutableBufferPointer { matchesBuffer in
                if let boosts {
                    return boosts.withUnsafeBufferPointer { boostsBuffer in
                        searchIndexWithBoosts(
                            index,
                            queryBuffer.baseAddress,
                            queryBuffer.count,
                            resultLimit,
                            boostsBuffer.baseAddress,
                            boostsCount,
                            UnsafeMutableRawPointer(matchesBuffer.baseAddress),
                            matchesBuffer.count,
                            &count
                        )
                    }
                } else {
                    return searchIndexWithBoosts(
                        index,
                        queryBuffer.baseAddress,
                        queryBuffer.count,
                        resultLimit,
                        nil,
                        0,
                        UnsafeMutableRawPointer(matchesBuffer.baseAddress),
                        matchesBuffer.count,
                        &count
                    )
                }
            }
        }
        guard status == 0 else { return nil }
        return Array(matches.prefix(count))
    }
}

// Sendable is safe here because the Swift payload entries are immutable, the
// raw index pointer is destroyed only in deinit, and Rust keeps per-thread
// matcher scratch state outside the immutable index.
final class CommandPaletteNucleoSearchIndex<Payload>: @unchecked Sendable where Payload: Sendable {
    private let library: CommandPaletteNucleoSearchLibrary
    private let pointer: OpaquePointer
    private let entries: [CommandPaletteSearchCorpusEntry<Payload>]

    init?(entries: [CommandPaletteSearchCorpusEntry<Payload>]) {
        guard let library = CommandPaletteNucleoSearchLibrary.shared,
              let pointer = library.createIndex(entries: entries) else {
            return nil
        }
        self.library = library
        self.pointer = pointer
        self.entries = entries
    }

    deinit {
        library.destroy(index: pointer)
    }

    func search(
        query: String,
        resultLimit: Int,
        historyBoost: ((Payload, Bool) -> Int)? = nil,
        shouldCancel: () -> Bool = { false }
    ) -> [CommandPaletteNucleoSearchResult<Payload>]? {
        guard resultLimit > 0 else { return [] }
        if shouldCancel() { return [] }

        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        let queryIsEmpty = preparedQuery.isEmpty
        let boosts: [Int32]?
        if let historyBoost {
            var values: [Int32] = []
            values.reserveCapacity(entries.count)
            var hasNonZeroBoost = false
            for entry in entries {
                let boost = Int32(clamping: historyBoost(entry.payload, queryIsEmpty))
                hasNonZeroBoost = hasNonZeroBoost || boost != 0
                values.append(boost)
            }
            boosts = hasNonZeroBoost ? values : nil
        } else {
            boosts = nil
        }
        guard let rawMatches = library.search(
            index: pointer,
            query: query,
            resultLimit: min(resultLimit, entries.count),
            boosts: boosts
        ) else {
            return nil
        }
        if shouldCancel() { return [] }

        var results: [CommandPaletteNucleoSearchResult<Payload>] = []
        results.reserveCapacity(rawMatches.count)
        for rawMatch in rawMatches {
            guard entries.indices.contains(rawMatch.index) else { continue }
            let entry = entries[rawMatch.index]
            let titleMatchIndices: Set<Int>
            if queryIsEmpty {
                titleMatchIndices = []
            } else {
                titleMatchIndices = entry.preparedTitle.map {
                    CommandPaletteFuzzyMatcher.matchCharacterIndices(
                        preparedQuery: preparedQuery,
                        preparedCandidate: $0
                    )
                } ?? []
            }
            results.append(
                CommandPaletteNucleoSearchResult(
                    payload: entry.payload,
                    rank: entry.rank,
                    title: entry.title,
                    score: Self.clampedRoundedScore(rawMatch.score),
                    titleMatchIndices: titleMatchIndices
                )
            )
        }
        return results
    }

    private static func clampedRoundedScore(_ score: Double) -> Int {
        let rounded = score.rounded()
        guard rounded.isFinite else {
            if rounded == .infinity { return Int.max }
            if rounded == -.infinity { return Int.min }
            return 0
        }
        if rounded >= Double(Int.max) { return Int.max }
        if rounded <= Double(Int.min) { return Int.min }
        return Int(rounded)
    }
}

fileprivate struct CommandPaletteNucleoCandidateSpan {
    let titleOffset: Int
    let titleLength: Int
    let searchOffset: Int
    let searchLength: Int
    let rank: Int32
}

fileprivate struct CommandPaletteNucleoRawMatch {
    var index: Int
    var score: Double
    var rank: Int32
}

private enum CommandPaletteNucleoABI {
    static func assertCompatibleLayout() {
        _ = checked
    }

    private static let checked: Void = {
        precondition(MemoryLayout<Int>.size == MemoryLayout<UInt>.size)
        precondition(MemoryLayout<CommandPaletteNucleoCandidateSpan>.size == 36)
        precondition(MemoryLayout<CommandPaletteNucleoCandidateSpan>.stride == 40)
        precondition(MemoryLayout<CommandPaletteNucleoCandidateSpan>.alignment == 8)
        precondition(MemoryLayout<CommandPaletteNucleoRawMatch>.size == 20)
        precondition(MemoryLayout<CommandPaletteNucleoRawMatch>.stride == 24)
        precondition(MemoryLayout<CommandPaletteNucleoRawMatch>.alignment == 8)
        precondition(MemoryLayout<CommandPaletteNucleoCandidateSpan>.offset(of: \.titleOffset) == 0)
        precondition(MemoryLayout<CommandPaletteNucleoCandidateSpan>.offset(of: \.titleLength) == 8)
        precondition(MemoryLayout<CommandPaletteNucleoCandidateSpan>.offset(of: \.searchOffset) == 16)
        precondition(MemoryLayout<CommandPaletteNucleoCandidateSpan>.offset(of: \.searchLength) == 24)
        precondition(MemoryLayout<CommandPaletteNucleoCandidateSpan>.offset(of: \.rank) == 32)
        precondition(MemoryLayout<CommandPaletteNucleoRawMatch>.offset(of: \.index) == 0)
        precondition(MemoryLayout<CommandPaletteNucleoRawMatch>.offset(of: \.score) == 8)
        precondition(MemoryLayout<CommandPaletteNucleoRawMatch>.offset(of: \.rank) == 16)
    }()
}
