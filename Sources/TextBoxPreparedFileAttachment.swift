import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A regular, readable file prepared for attachment without carrying UI objects
/// across the background-work boundary.
nonisolated struct TextBoxPreparedFileAttachment: Sendable {
    let fileURL: URL
    let thumbnailPixelData: Data?
    let thumbnailPixelWidth: Int
    let thumbnailPixelHeight: Int
    let thumbnailBytesPerRow: Int

    private static let thumbnailMaximumPixelSize = 512
    private static let maximumThumbnailSourceBytes = 32 * 1024 * 1024

    /// Validates and optionally downsamples one file on a concurrent executor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func prepare(fileURL: URL) async -> TextBoxPreparedFileAttachment? {
        #if compiler(>=6.2)
        prepareSynchronously(fileURL: fileURL)
        #else
        await Task.detached(priority: .userInitiated) {
            prepareSynchronously(fileURL: fileURL)
        }.value
        #endif
    }

    private static func prepareSynchronously(
        fileURL: URL
    ) -> TextBoxPreparedFileAttachment? {
        guard fileURL.isFileURL else { return nil }

        let descriptor = fileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }

            var metadata = stat()
            guard Darwin.lstat(path, &metadata) == 0,
                  isRegularFile(metadata) || isSymbolicLink(metadata) else {
                return -1
            }

            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              isRegularFile(metadata) else {
            return nil
        }

        let thumbnail = preparedThumbnail(
            descriptor: descriptor,
            fileSize: metadata.st_size,
            fileURL: fileURL
        )
        return TextBoxPreparedFileAttachment(
            fileURL: fileURL.standardizedFileURL,
            thumbnailPixelData: thumbnail?.pixelData,
            thumbnailPixelWidth: thumbnail?.width ?? 0,
            thumbnailPixelHeight: thumbnail?.height ?? 0,
            thumbnailBytesPerRow: thumbnail?.bytesPerRow ?? 0
        )
    }

    private static func isRegularFile(_ metadata: stat) -> Bool {
        (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    private static func isSymbolicLink(_ metadata: stat) -> Bool {
        (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
    }

    private static func preparedThumbnail(
        descriptor: Int32,
        fileSize: off_t,
        fileURL: URL
    ) -> (pixelData: Data, width: Int, height: Int, bytesPerRow: Int)? {
        let pathExtension = fileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension),
              type.conforms(to: .image),
              fileSize > 0,
              fileSize <= off_t(maximumThumbnailSourceBytes),
              let sourceData = readFile(
                descriptor: descriptor,
                byteCount: Int(fileSize)
              ) else {
            return nil
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, sourceOptions) else {
            return nil
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaximumPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
              image.width > 0,
              image.height > 0 else {
            return nil
        }

        let bytesPerRow = image.width * 4
        var pixelData = Data(count: bytesPerRow * image.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let didDraw = pixelData.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo.rawValue
                  ) else {
                return false
            }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard didDraw else { return nil }
        return (pixelData, image.width, image.height, bytesPerRow)
    }

    private static func readFile(descriptor: Int32, byteCount: Int) -> Data? {
        guard byteCount > 0, byteCount <= maximumThumbnailSourceBytes else { return nil }
        var data = Data(count: byteCount)
        let bytesRead = data.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            var offset = 0
            while offset < byteCount {
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    byteCount - offset
                )
                if result > 0 {
                    offset += result
                    continue
                }
                if result < 0, errno == EINTR {
                    continue
                }
                break
            }
            return offset
        }
        guard bytesRead == byteCount else { return nil }
        return data
    }
}
