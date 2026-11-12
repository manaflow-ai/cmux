import Foundation

extension PastedImage {
    /// Whether every segment (JPEG) or chunk (PNG) of `data` is one that holds pixels or describes
    /// them: an allow-list over the file's own structure, for what ImageIO's properties do not show
    /// (a JPEG comment, PNG text chunks, an unknown APPn segment or chunk). Fails closed: an unknown
    /// segment or chunk, a truncated file, or another format is false.
    ///
    /// JPEG: APP0 JFIF/JFXX, APP1 Exif or XMP (their contents are checked by
    /// ``carriesMetadata(_:properties:)``), APP2 ICC profile, APP14 Adobe (the color transform), and
    /// the tables, frames, scans and restart markers. PNG: the critical chunks, the color and
    /// resolution chunks, `eXIf` and an XMP `iTXt` (checked as above), and Apple's `iDOT` (the
    /// offsets ImageIO's encoder writes for parallel decoding).
    static func holdsOnlyPixelSegments(_ data: Data, type: String) -> Bool {
        data.withUnsafeBytes { bytes in
            switch type {
            case "public.jpeg": jpegSegmentsAreClean(bytes)
            case "public.png": pngChunksAreClean(bytes)
            default: false
            }
        }
    }
}

/// The JPEG markers that stand alone, with no length: TEM and the restart markers.
private func standsAlone(_ marker: UInt8) -> Bool {
    marker == 0x01 || (0xD0...0xD7).contains(marker)
}

/// Whether the payload at `start` begins with `prefix`.
private func payload(_ bytes: UnsafeRawBufferPointer, at start: Int, end: Int, startsWith prefix: String) -> Bool {
    let prefix = Array(prefix.utf8)
    guard end - start >= prefix.count else { return false }
    return prefix.indices.allSatisfy { bytes[start + $0] == prefix[$0] }
}

private func jpegSegmentsAreClean(_ bytes: UnsafeRawBufferPointer) -> Bool {
    guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }
    var index = 2
    while index + 1 < bytes.count {
        guard bytes[index] == 0xFF else { return false }
        var marker = bytes[index + 1]
        // Fill bytes before a marker.
        while marker == 0xFF, index + 2 < bytes.count {
            index += 1
            marker = bytes[index + 1]
        }
        if marker == 0xD9 { return true }
        if standsAlone(marker) {
            index += 2
            continue
        }
        guard index + 3 < bytes.count else { return false }
        let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
        let start = index + 4, end = index + 2 + length
        guard length >= 2, end <= bytes.count else { return false }
        let allowed: Bool
        switch marker {
        case 0xE0: allowed = payload(bytes, at: start, end: end, startsWith: "JFIF\0")
            || payload(bytes, at: start, end: end, startsWith: "JFXX\0")
        case 0xE1: allowed = payload(bytes, at: start, end: end, startsWith: "Exif\0\0")
            || payload(bytes, at: start, end: end, startsWith: "http://ns.adobe.com/xap/1.0/\0")
        case 0xE2: allowed = payload(bytes, at: start, end: end, startsWith: "ICC_PROFILE\0")
        case 0xEE: allowed = payload(bytes, at: start, end: end, startsWith: "Adobe")
        // DQT, DHT, DAC, DRI, DNL and the frame headers (SOF0-15 but DHT, JPG and DAC).
        case 0xDB, 0xC4, 0xCC, 0xDD, 0xDC: allowed = true
        case 0xC0...0xCF where marker != 0xC8: allowed = true
        case 0xDA: allowed = true
        default: allowed = false
        }
        guard allowed else { return false }
        index = end
        if marker == 0xDA {
            // The scan's coded data: up to the next marker that is not a stuffed 0 or a restart.
            while index + 1 < bytes.count {
                if bytes[index] == 0xFF, bytes[index + 1] != 0x00, !standsAlone(bytes[index + 1]), bytes[index + 1] != 0xFF {
                    break
                }
                index += 1
            }
        }
    }
    return false
}

private func pngChunksAreClean(_ bytes: UnsafeRawBufferPointer) -> Bool {
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard bytes.count >= 8, signature.indices.allSatisfy({ bytes[$0] == signature[$0] }) else { return false }
    let allowed: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND", "tRNS", "gAMA", "cHRM", "sRGB", "iCCP", "cICP", "pHYs", "sBIT", "bKGD",
        "eXIf", "iDOT",
    ]
    var index = 8
    while index + 8 <= bytes.count {
        let length = (0..<4).reduce(0) { $0 << 8 | Int(bytes[index + $1]) }
        let type = String(decoding: (4..<8).map { bytes[index + $0] }, as: UTF8.self)
        let start = index + 8, end = start + length
        guard length >= 0, end + 4 <= bytes.count else { return false }
        let xmp = type == "iTXt" && payload(bytes, at: start, end: end, startsWith: "XML:com.adobe.xmp\0")
        guard allowed.contains(type) || xmp else { return false }
        if type == "IEND" { return true }
        index = end + 4
    }
    return false
}
