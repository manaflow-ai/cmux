public import Foundation
import CCmuxWallpaperFFI

/// One live wallpaper (plans/cmux-next/live-wallpapers.md): a WGSL program the GPU runs for every
/// pixel of the backdrop, with its checked manifest. The app reads only the first-party set the
/// Rust library carries (`cmux_wallpaper_first_party_*`); its Metal program was translated when that
/// library was built, so the app never compiles WGSL and never loads a program the validator refused.
/// Extension wallpapers (`contributes.wallpapers`, `live:<extension>/<id>`) do not load yet.
public nonisolated struct LiveWallpaper: Sendable, Equatable, Identifiable {
    /// The manifest's `id`, a slug; the selection's id is `live:<id>` (``BackdropSelection/live(_:)``).
    public let id: String
    public let name: String
    public let summary: String
    /// The program's own frame cap, 1...60; the scheduler takes the lower of it and Settings'.
    public let fps: UInt32
    /// The backing scale it renders at, 0.25...1.
    public let scale: Float
    /// Whether pointer motion wakes it.
    public let interactive: Bool
    /// Seconds with no pointer move, key or theme change before it holds (the manifest's `idle_after`).
    public let idleAfter: Double
    /// The manifest's params' defaults in order, at most 8.
    public let params: [Float]
    /// A still's time (seconds) and pointer (fractions of the size).
    public let stillTime: Float
    public let stillPointer: (x: Float, y: Float)
    /// Its index in the first-party set (`cmux_wallpaper_first_party_msl`).
    let index: Int
    /// A digest of its WGSL source: the program cache's key with ``id``.
    let sourceDigest: UInt64

    public static func == (lhs: LiveWallpaper, rhs: LiveWallpaper) -> Bool {
        lhs.id == rhs.id && lhs.sourceDigest == rhs.sourceDigest
    }

    /// The ABI the app was written against (`cmux_wallpaper_abi_version`): 4 has the first-party
    /// Metal programs translated at build time and no WGSL compiler in the app.
    static let abiVersion: UInt32 = 4

    /// The ABI of the linked library (`cmux_wallpaper_abi_version`).
    static var linkedABIVersion: UInt32 { cmux_wallpaper_abi_version() }

    /// The first-party set, sorted by id; empty when the linked library speaks another ABI. Read
    /// once per process from static bytes in the library (no file, no network).
    public static let firstParty: [LiveWallpaper] = {
        guard cmux_wallpaper_abi_version() == abiVersion else { return [] }
        return (0..<cmux_wallpaper_first_party_count()).compactMap(LiveWallpaper.init(firstParty:))
    }()

    /// The first-party wallpaper `id`, or nil (an unknown id, an extension's wallpaper).
    public static func named(_ id: String) -> LiveWallpaper? {
        firstParty.first { $0.id == id }
    }

    /// The selections of the picker's Live wallpapers group, in the set's order.
    public static var choices: [BackdropSelection] { firstParty.map { .live($0.id) } }

    private init?(firstParty index: Int) {
        var length = 0
        guard let bytes = cmux_wallpaper_first_party_manifest_json(index, &length), length > 0 else { return nil }
        // The manifest through the same validator extensions get: every optional key filled in.
        guard let checked = cmux_wallpaper_validate_manifest(bytes, length) else { return nil }
        defer { cmux_wallpaper_manifest_result_free(checked) }
        guard checked.pointee.ok, let text = checked.pointee.json,
              let object = try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else { return nil }
        let still = object["still"] as? [String: Any]
        let pointer = (still?["pointer"] as? [NSNumber])?.map(\.floatValue) ?? []
        self.index = index
        self.id = id
        name = object["name"] as? String ?? id
        summary = object["description"] as? String ?? ""
        fps = (object["fps"] as? NSNumber)?.uint32Value ?? 30
        scale = (object["scale"] as? NSNumber)?.floatValue ?? 1
        interactive = (object["interactive"] as? Bool) ?? true
        idleAfter = (object["idle_after"] as? NSNumber)?.doubleValue ?? 20
        params = ((object["params"] as? [[String: Any]]) ?? []).prefix(8).map { ($0["default"] as? NSNumber)?.floatValue ?? 0 }
        stillTime = (still?["time"] as? NSNumber)?.floatValue ?? 0
        stillPointer = (pointer.first ?? 0.5, pointer.dropFirst().first ?? 0.5)
        var sourceLength = 0
        let source = cmux_wallpaper_first_party_source(index, &sourceLength)
        sourceDigest = Self.digest(source.map { UnsafeBufferPointer(start: $0, count: sourceLength) })
    }

    /// The Metal Shading Language program (`vertex vs_main`, `fragment fs_main`, the Frame
    /// uniform at buffer 0 in both), translated from the WGSL when the library was built.
    var metalSource: String? {
        var length = 0
        guard let bytes = cmux_wallpaper_first_party_msl(index, &length), length > 0 else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
    }

    /// A 64-bit FNV-1a digest of `bytes` (0 for none).
    private static func digest(_ bytes: UnsafeBufferPointer<UInt8>?) -> UInt64 {
        guard let bytes else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
