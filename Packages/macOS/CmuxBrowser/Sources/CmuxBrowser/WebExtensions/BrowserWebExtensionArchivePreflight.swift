public import Foundation

/// Validates bounded ZIP/XPI metadata without extracting untrusted content.
public struct BrowserWebExtensionArchivePreflight: Sendable {
    public init() {}

    public func validate(
        _ data: Data,
        packageName: String,
        limits: BrowserWebExtensionArchiveLimits
    ) throws {
        guard data.count <= limits.maximumCompressedByteCount else {
            throw BrowserWebExtensionInstallError.packageTooLarge
        }
        guard let endOffset = endOfCentralDirectoryOffset(in: data) else {
            throw BrowserWebExtensionInstallError.invalidPackage(packageName)
        }
        let diskNumber = try data.littleEndianUInt16(at: endOffset + 4, packageName: packageName)
        let centralDisk = try data.littleEndianUInt16(at: endOffset + 6, packageName: packageName)
        let diskEntryCount = try data.littleEndianUInt16(at: endOffset + 8, packageName: packageName)
        let entryCount = try data.littleEndianUInt16(at: endOffset + 10, packageName: packageName)
        let centralSize = try data.littleEndianUInt32(at: endOffset + 12, packageName: packageName)
        let centralOffset = try data.littleEndianUInt32(at: endOffset + 16, packageName: packageName)
        guard diskNumber == 0,
              centralDisk == 0,
              diskEntryCount == entryCount,
              entryCount != .max,
              centralSize != .max,
              centralOffset != .max,
              Int(entryCount) <= limits.maximumEntryCount else {
            if Int(entryCount) > limits.maximumEntryCount {
                throw BrowserWebExtensionInstallError.packageContainsTooManyFiles
            }
            throw BrowserWebExtensionInstallError.invalidPackage(packageName)
        }

        let centralStart = Int(centralOffset)
        let centralEnd = try checkedAdd(centralStart, Int(centralSize), packageName: packageName)
        guard centralEnd <= endOffset else {
            throw BrowserWebExtensionInstallError.invalidPackage(packageName)
        }
        var cursor = centralStart
        var expandedByteCount = 0
        var entryPaths = Set<String>()
        for _ in 0..<Int(entryCount) {
            guard try data.littleEndianUInt32(at: cursor, packageName: packageName) == 0x0201_4b50 else {
                throw BrowserWebExtensionInstallError.invalidPackage(packageName)
            }
            let versionMadeBy = try data.littleEndianUInt16(at: cursor + 4, packageName: packageName)
            let flags = try data.littleEndianUInt16(at: cursor + 8, packageName: packageName)
            let compressedSize = try data.littleEndianUInt32(at: cursor + 20, packageName: packageName)
            let expandedSize = try data.littleEndianUInt32(at: cursor + 24, packageName: packageName)
            let nameLength = Int(try data.littleEndianUInt16(at: cursor + 28, packageName: packageName))
            let extraLength = Int(try data.littleEndianUInt16(at: cursor + 30, packageName: packageName))
            let commentLength = Int(try data.littleEndianUInt16(at: cursor + 32, packageName: packageName))
            let diskStart = try data.littleEndianUInt16(at: cursor + 34, packageName: packageName)
            let externalAttributes = try data.littleEndianUInt32(at: cursor + 38, packageName: packageName)
            let localOffset = try data.littleEndianUInt32(at: cursor + 42, packageName: packageName)
            guard flags & 0x1 == 0,
                  compressedSize != .max,
                  expandedSize != .max,
                  localOffset != .max,
                  diskStart == 0 else {
                throw BrowserWebExtensionInstallError.invalidPackage(packageName)
            }
            let nameStart = try checkedAdd(cursor, 46, packageName: packageName)
            let nameEnd = try checkedAdd(nameStart, nameLength, packageName: packageName)
            let nextCursor = try checkedAdd(
                nameEnd,
                try checkedAdd(extraLength, commentLength, packageName: packageName),
                packageName: packageName
            )
            guard nextCursor <= centralEnd,
                  let path = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
                throw BrowserWebExtensionInstallError.invalidPackage(packageName)
            }
            try validatePath(path, packageName: packageName)
            let entryPath = path.hasSuffix("/") ? String(path.dropLast()) : path
            guard entryPaths.insert(entryPath).inserted else {
                throw BrowserWebExtensionInstallError.invalidPackage(packageName)
            }
            let platform = versionMadeBy >> 8
            let fileType = (externalAttributes >> 16) & 0xf000
            if (platform == 3 || platform == 19) && fileType == 0xa000 {
                throw BrowserWebExtensionInstallError.symbolicLinksNotAllowed
            }
            guard expandedByteCount <= limits.maximumExpandedByteCount - Int(expandedSize) else {
                throw BrowserWebExtensionInstallError.packageTooLarge
            }
            expandedByteCount += Int(expandedSize)
            try validateLocalHeader(
                in: data,
                offset: Int(localOffset),
                expectedName: data[nameStart..<nameEnd],
                compressedSize: Int(compressedSize),
                centralOffset: centralStart,
                packageName: packageName
            )
            cursor = nextCursor
        }
        guard cursor == centralEnd else {
            throw BrowserWebExtensionInstallError.invalidPackage(packageName)
        }
    }

    private func endOfCentralDirectoryOffset(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowerBound = max(0, data.count - (22 + Int(UInt16.max)))
        for offset in stride(from: data.count - 22, through: lowerBound, by: -1) {
            guard data.uncheckedLittleEndianUInt32(at: offset) == 0x0605_4b50 else { continue }
            let commentLength = Int(data.uncheckedLittleEndianUInt16(at: offset + 20))
            if offset + 22 + commentLength == data.count { return offset }
        }
        return nil
    }

    private func validatePath(_ path: String, packageName: String) throws {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              components.first?.contains(":") != true else {
            throw BrowserWebExtensionInstallError.invalidPackage(packageName)
        }
    }

    private func validateLocalHeader(
        in data: Data,
        offset: Int,
        expectedName: Data.SubSequence,
        compressedSize: Int,
        centralOffset: Int,
        packageName: String
    ) throws {
        guard try data.littleEndianUInt32(at: offset, packageName: packageName) == 0x0403_4b50 else {
            throw BrowserWebExtensionInstallError.invalidPackage(packageName)
        }
        let nameLength = Int(try data.littleEndianUInt16(at: offset + 26, packageName: packageName))
        let extraLength = Int(try data.littleEndianUInt16(at: offset + 28, packageName: packageName))
        let nameStart = try checkedAdd(offset, 30, packageName: packageName)
        let nameEnd = try checkedAdd(nameStart, nameLength, packageName: packageName)
        let dataStart = try checkedAdd(nameEnd, extraLength, packageName: packageName)
        let dataEnd = try checkedAdd(dataStart, compressedSize, packageName: packageName)
        guard dataEnd <= centralOffset,
              data[nameStart..<nameEnd].elementsEqual(expectedName) else {
            throw BrowserWebExtensionInstallError.invalidPackage(packageName)
        }
    }

    private func checkedAdd(_ lhs: Int, _ rhs: Int, packageName: String) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, lhs >= 0, rhs >= 0 else {
            throw BrowserWebExtensionInstallError.invalidPackage(packageName)
        }
        return result
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int, packageName: String) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else {
            throw BrowserWebExtensionInstallError.invalidPackage(packageName)
        }
        return uncheckedLittleEndianUInt16(at: offset)
    }

    func littleEndianUInt32(at offset: Int, packageName: String) throws -> UInt32 {
        guard offset >= 0, offset <= count - 4 else {
            throw BrowserWebExtensionInstallError.invalidPackage(packageName)
        }
        return uncheckedLittleEndianUInt32(at: offset)
    }

    func uncheckedLittleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uncheckedLittleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
