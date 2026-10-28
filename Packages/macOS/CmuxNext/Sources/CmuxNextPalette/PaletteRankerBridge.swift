import CmuxNextCompat
public import Foundation
import CCmuxPaletteRankerFFI

/// Errors raised while loading or invoking the shared palette ranker.
public enum PaletteRankerBridgeError: Error, LocalizedError, Sendable {
    /// The Rust ranker could not allocate its handle.
    case runtimeUnavailable
    /// The shared ranker refused a request.
    case runtimeFailed(String)
    /// The ranker returned a value that is not a ranked-section payload.
    case invalidResult

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            "the shared palette ranker could not be created"
        case .runtimeFailed(let message):
            "the shared palette ranker failed: \(message)"
        case .invalidResult:
            "the shared palette ranker returned an invalid result"
        }
    }
}

/// Thin native caller of the shared Rust ranker (cmux-tui/crates/cmux-palette-ranker, linked
/// through CCmuxAppFFI).
///
/// A bridge owns one ranker handle and is safe to use from the actor that owns it. The palette
/// keeps ranking inputs and rendering in Swift; scoring, frecency and tie-breaking live in Rust.
// SAFETY: `handle` is the ranker this object created and alone frees (deinit), so it is live for every call made
// through it.
@safe public final class PaletteRankerBridge {
    // crash-allow: the handle is serialized by each owning actor or Mutex-protected ranker.
    nonisolated(unsafe) private let handle: OpaquePointer
    /// The index version whose entries the ranker holds: a keystroke on the same index sends only
    /// the query, not 2,000 entries to encode and parse again.
    // crash-allow: serialized with `handle` by the owning actor.
    nonisolated(unsafe) private var installedVersion: Int?

    /// Creates a bridge with its own ranker handle.
    nonisolated public init() throws {
        // SAFETY: cmux_palette_ranker_new returns a new handle this object owns alone and frees in deinit.
        guard let handle = unsafe cmux_palette_ranker_new() else { throw PaletteRankerBridgeError.runtimeUnavailable }
        unsafe self.handle = handle
    }

    nonisolated deinit {
        // SAFETY: the handle init created, freed once here; no call on it can run after deinit starts.
        unsafe cmux_palette_ranker_free(handle)
    }

    /// Ranks a palette index through the shared ranker.
    nonisolated public func rank(
        index: PaletteSearchIndex,
        version: Int? = nil,
        query: String,
        sectionOrders: [Int],
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        keepsSectionOrder: Bool = false,
        ranksPrefixFirst: Bool = false,
        recentLimit: Int = 5,
        rowLimit: Int = 400,
        highlightLimit: Int = 60,
        settings: PaletteRankSettings = PaletteRankSettings()
    ) throws -> [PaletteRankedSection] {
        if let version, version != installedVersion { try install(index.entries, version: version) }
        return try invoke(PaletteRankerBridgeRequest(
            operation: .rank,
            entries: version == nil ? index.entries.map(PaletteRankerBridgeEntry.init) : nil,
            version: version,
            query: query,
            sectionOrders: sectionOrders,
            frecency: PaletteRankerBridgeFrecency(frecency, query: query),
            now: now.timeIntervalSinceReferenceDate,
            showsRecent: showsRecent,
            keepsSectionOrder: keepsSectionOrder,
            ranksPrefixFirst: ranksPrefixFirst,
            recentLimit: recentLimit,
            aliases: settings.aliases.isEmpty ? nil : settings.aliases,
            pins: nil,
            pinnedSectionIndex: nil,
            rowLimit: rowLimit,
            highlightLimit: highlightLimit
        ))
    }

    /// Ranks an empty palette query through the shared ranker.
    ///
    /// - Parameter version: The snapshot identifier of `entries`. With one, the entries go to the
    ///   ranker once per version (`cmux_palette_ranker_install`), shared with the typed queries of the
    ///   same snapshot; without one, every call sends them all.
    nonisolated public func rankEmpty(
        entries: [PaletteSearchEntry],
        version: Int? = nil,
        sectionOrders: [Int],
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        recentLimit: Int = 5,
        settings: PaletteRankSettings = PaletteRankSettings(),
        pinnedSectionIndex: Int? = nil
    ) throws -> [PaletteRankedSection] {
        if let version, version != installedVersion { try install(entries, version: version) }
        return try invoke(PaletteRankerBridgeRequest(
            operation: .rankEmpty,
            entries: version == nil ? entries.map(PaletteRankerBridgeEntry.init) : nil,
            version: version,
            query: nil,
            sectionOrders: sectionOrders,
            frecency: PaletteRankerBridgeFrecency(frecency),
            now: now.timeIntervalSinceReferenceDate,
            showsRecent: showsRecent,
            keepsSectionOrder: false,
            ranksPrefixFirst: false,
            recentLimit: recentLimit,
            aliases: nil,
            pins: settings.pins.isEmpty ? nil : settings.pins,
            pinnedSectionIndex: pinnedSectionIndex,
            rowLimit: 400,
            highlightLimit: 60
        ))
    }

    /// Sends `entries` to the ranker once for `version`.
    nonisolated private func install(_ entries: [PaletteSearchEntry], version: Int) throws {
        let data = try JSONEncoder().encode(entries.map(PaletteRankerBridgeEntry.init))
        // SAFETY: `bytes` is Data's contiguous storage, valid only inside the closure; the ranker reads bytes.count
        // bytes from its start during the call and keeps none of them (it parses them into its own entries).
        let code = unsafe data.withUnsafeBytes { bytes in
            unsafe cmux_palette_ranker_install(handle, Int64(version), bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        guard code == CMUX_PALETTE_RANKER_OK else {
            installedVersion = nil
            throw PaletteRankerBridgeError.runtimeFailed("entries were refused (\(code))")
        }
        installedVersion = version
    }

    nonisolated private func invoke(_ request: PaletteRankerBridgeRequest) throws -> [PaletteRankedSection] {
        let data = try JSONEncoder().encode(request)
        var response: UnsafePointer<UInt8>?
        var responseLength = 0
        // SAFETY: `bytes` is Data's contiguous storage, valid only inside the closure; the ranker reads bytes.count
        // bytes from its start during the call and keeps none of them. It writes one pointer and one length into
        // `response` and `responseLength`, locals live for the call: responseLength bytes it owns, valid until the
        // next call on this handle (cmux_palette_ranker.h), copied into `body` before any other call can run on it.
        let code = unsafe data.withUnsafeBytes { bytes in
            unsafe cmux_palette_ranker_rank(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response, &responseLength)
        }
        guard let response = unsafe response else { throw PaletteRankerBridgeError.invalidResult }
        let body = unsafe Data(bytes: response, count: responseLength)
        guard code == CMUX_PALETTE_RANKER_OK else {
            throw PaletteRankerBridgeError.runtimeFailed(String(decoding: body, as: UTF8.self))
        }
        do {
            let sections = try JSONDecoder().blockingDecode([PaletteRankerBridgeSection].self, from: body)
            return sections.map { section in
                PaletteRankedSection(
                    sectionIndex: section.sectionIndex,
                    rows: section.rows.map { row in
                        PaletteRankedRow(index: row.index, score: row.score, highlights: row.highlights)
                    }
                )
            }
        } catch {
            throw PaletteRankerBridgeError.runtimeFailed("invalid result JSON: \(error)")
        }
    }
}
