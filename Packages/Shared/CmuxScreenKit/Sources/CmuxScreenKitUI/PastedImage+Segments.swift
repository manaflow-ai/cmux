import Foundation

extension PastedImage {
    /// `data` rebuilt from only the segments (JPEG) or chunks (PNG) that hold its pixels or say how
    /// to show them, in their order and byte for byte: the scans and `IDAT` are not touched, so the
    /// pixels are the same. Everything else is dropped, by an allow-list of type and content, so an
    /// unknown segment never passes: a JPEG comment, APP1 (EXIF, XMP), APP2 other than an ICC
    /// profile (MPF), APP3 to APP13 (Photoshop and IPTC), APP15, PNG text chunks, `eXIf`, `tIME`,
    /// Apple's `iDOT` (offsets that dropping a chunk would make wrong), any other ancillary chunk,
    /// and anything after the end of the image (a gain map or other second image).
    ///
    /// Nil, so the caller decodes or refuses, for a segment that cannot go and cannot be dropped
    /// either (APP14 Adobe, which says how to read CMYK colors; an unknown JPEG marker; an unknown
    /// critical PNG chunk), a damaged file (``isDamaged(_:type:)``), or another format.
    ///
    /// JPEG keeps: APP0 JFIF with its thumbnail cut (written as 0 x 0, so an old picture never goes;
    /// JFXX, which exists only for thumbnails, is dropped), APP2 `ICC_PROFILE` (the color profile),
    /// the quantization and
    /// Huffman tables, DAC, DRI, DNL, the frame headers, the scans with their restart markers, and
    /// the end. PNG keeps: `IHDR`, `PLTE`, `IDAT`, `IEND`, and the color and size chunks `tRNS`,
    /// `gAMA`, `cHRM`, `sRGB`, `iCCP`, `cICP`, `sBIT`, `bKGD`, `pHYs`.
    static func pixelSegmentsOnly(_ data: Data, type: String) -> Data? {
        if case .rebuilt(let rebuilt) = walk(data, type: type) { return rebuilt }
        return nil
    }

    /// Whether `data`, a JPEG or PNG by its `type`, is damaged: a segment or chunk that runs past
    /// the end, a scan or file cut off before its end marker, or not the format at all. A damaged
    /// photo is refused, never decoded: what a decoder makes of it is not what the person picked.
    static func isDamaged(_ data: Data, type: String) -> Bool {
        if case .damaged = walk(data, type: type) { return true }
        return false
    }

    private static func walk(_ data: Data, type: String) -> Walk {
        data.withUnsafeBytes { bytes in
            switch type {
            case "public.jpeg": jpegPixelSegments(bytes)
            case "public.png": pngPixelChunks(bytes)
            default: .damaged
            }
        }
    }
}

/// What a walk over a file's segments or chunks found.
private enum Walk {
    /// The file rebuilt from its pixel segments only.
    case rebuilt(Data)
    /// Whole, but with a segment that can neither go nor be dropped (APP14, an unknown marker or
    /// critical chunk).
    case notCopyable
    /// Cut off, a length past the end, or not the format.
    case damaged
}

/// The JPEG markers that stand alone, with no length: TEM and the restart markers.
private func standsAlone(_ marker: UInt8) -> Bool {
    marker == 0x01 || (0xD0...0xD7).contains(marker)
}

/// Whether the bytes from `start` to `end` begin with `prefix`.
private func payload(_ bytes: UnsafeRawBufferPointer, from start: Int, to end: Int, startsWith prefix: String) -> Bool {
    let prefix = Array(prefix.utf8)
    guard end - start >= prefix.count else { return false }
    return prefix.indices.allSatisfy { bytes[start + $0] == prefix[$0] }
}

/// What to do with one JPEG segment.
private enum Keep { case keep, jfif, drop, refuse }

/// The bytes of a JFIF APP0 segment before its thumbnail: "JFIF\0", version, units, densities, and
/// the thumbnail's width and height.
private let jfifHeaderBytes = 14

private func jpegSegment(_ marker: UInt8, _ bytes: UnsafeRawBufferPointer, from start: Int, to end: Int) -> Keep {
    switch marker {
    case 0xE0:
        let jfif = payload(bytes, from: start, to: end, startsWith: "JFIF\0") && end - start >= jfifHeaderBytes
        return jfif ? .jfif : .drop
    case 0xE2: return payload(bytes, from: start, to: end, startsWith: "ICC_PROFILE\0") ? .keep : .drop
    case 0xEE: return .refuse
    case 0xE1, 0xE3...0xED, 0xEF, 0xFE: return .drop
    // DQT, DHT, DAC, DRI, DNL, and the frame headers (SOF0 to SOF15 but DHT, JPG and DAC).
    case 0xDB, 0xC4, 0xCC, 0xDD, 0xDC: return .keep
    case 0xC0...0xCF where marker != 0xC8: return .keep
    default: return .refuse
    }
}

private func jpegPixelSegments(_ bytes: UnsafeRawBufferPointer) -> Walk {
    guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return .damaged }
    var copyable = true
    var out = Data([0xFF, 0xD8])
    var index = 2
    while index + 1 < bytes.count {
        guard bytes[index] == 0xFF else { return .damaged }
        let marker = bytes[index + 1]
        if marker == 0xFF {
            // A fill byte before a marker.
            index += 1
            continue
        }
        if marker == 0xD9 {
            out.append(contentsOf: [0xFF, 0xD9])
            return copyable ? .rebuilt(out) : .notCopyable
        }
        if standsAlone(marker) {
            out.append(contentsOf: [0xFF, marker])
            index += 2
            continue
        }
        guard index + 3 < bytes.count else { return .damaged }
        let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
        let start = index + 4, end = index + 2 + length
        guard length >= 2, end <= bytes.count else { return .damaged }
        if marker == 0xDA {
            // The scan header, then its coded data up to the next marker that is not a stuffed 0 or
            // a restart: copied whole.
            var scanEnd = end
            while scanEnd + 1 < bytes.count {
                let next = bytes[scanEnd + 1]
                if bytes[scanEnd] == 0xFF, next != 0x00, next != 0xFF, !standsAlone(next) { break }
                scanEnd += 1
            }
            guard scanEnd + 1 < bytes.count else { return .damaged }
            out.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[index..<scanEnd]))
            index = scanEnd
            continue
        }
        switch jpegSegment(marker, bytes, from: start, to: end) {
        case .keep: out.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[index..<end]))
        case .jfif:
            // The header only, its thumbnail size written as 0 x 0 and the length fixed to match.
            out.append(contentsOf: [0xFF, 0xE0, 0x00, UInt8(jfifHeaderBytes + 2)])
            out.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[start..<(start + jfifHeaderBytes - 2)]))
            out.append(contentsOf: [0x00, 0x00])
        case .drop: break
        case .refuse: copyable = false
        }
        index = end
    }
    return .damaged
}

private func pngPixelChunks(_ bytes: UnsafeRawBufferPointer) -> Walk {
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard bytes.count >= 8, signature.indices.allSatisfy({ bytes[$0] == signature[$0] }) else { return .damaged }
    var copyable = true
    let kept: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND", "tRNS", "gAMA", "cHRM", "sRGB", "iCCP", "cICP", "sBIT", "bKGD", "pHYs",
    ]
    var out = Data(signature)
    var index = 8
    while index + 8 <= bytes.count {
        let length = (0..<4).reduce(0) { $0 << 8 | Int(bytes[index + $1]) }
        let typeBytes = (4..<8).map { bytes[index + $0] }
        let type = String(decoding: typeBytes, as: UTF8.self)
        // A length is at most 2^31 - 1 (PNG); a larger one is damage, as is one past the end.
        let end = index + 8 + length + 4
        guard length <= Int(Int32.max), end <= bytes.count else { return .damaged }
        if kept.contains(type) {
            out.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[index..<end]))
            if type == "IEND" { return copyable ? .rebuilt(out) : .notCopyable }
        } else if typeBytes[0] & 0x20 == 0 {
            // An unknown critical chunk (upper-case first letter): the image needs it to be read.
            copyable = false
        }
        index = end
    }
    return .damaged
}
