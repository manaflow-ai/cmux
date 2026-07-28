import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Immutable ownership captured while a file is prepared away from the main
/// actor. The disposition drives attachment cleanup without re-querying the
/// filesystem during UI insertion.
nonisolated enum TextBoxPreparedLocalFileDisposition: Sendable, Equatable {
    /// The file belongs to the caller and must never be deleted by cmux.
    case callerOwned
    /// The pasteboard service owns the temporary image. A durable draft-copy
    /// preflight has already started before the prepared value is returned.
    case cmuxTemporaryImage
    /// The file is already a cmux-owned durable draft copy.
    case cmuxDraftCopy

    var cleanupLocalURLWhenDisposed: Bool {
        switch self {
        case .callerOwned:
            false
        case .cmuxTemporaryImage, .cmuxDraftCopy:
            true
        }
    }
}

/// A regular, readable file prepared for attachment without carrying UI objects
/// across the background-work boundary.
nonisolated struct TextBoxPreparedFileAttachment: Sendable {
    let fileURL: URL
    let displayName: String
    let thumbnailPixelData: Data?
    let thumbnailPixelWidth: Int
    let thumbnailPixelHeight: Int
    let thumbnailBytesPerRow: Int
    let localFileDisposition: TextBoxPreparedLocalFileDisposition
    let cleanupPathEntryIdentity: TextBoxPreparedLocalFileIdentity?

    init(
        fileURL: URL,
        thumbnailPixelData: Data?,
        thumbnailPixelWidth: Int,
        thumbnailPixelHeight: Int,
        thumbnailBytesPerRow: Int,
        localFileDisposition: TextBoxPreparedLocalFileDisposition,
        displayName: String? = nil
    ) {
        self.init(
            fileURL: fileURL,
            thumbnailPixelData: thumbnailPixelData,
            thumbnailPixelWidth: thumbnailPixelWidth,
            thumbnailPixelHeight: thumbnailPixelHeight,
            thumbnailBytesPerRow: thumbnailBytesPerRow,
            localFileDisposition: localFileDisposition,
            cleanupPathEntryIdentity: nil,
            displayName: displayName
        )
    }

    private init(
        fileURL: URL,
        thumbnailPixelData: Data?,
        thumbnailPixelWidth: Int,
        thumbnailPixelHeight: Int,
        thumbnailBytesPerRow: Int,
        localFileDisposition: TextBoxPreparedLocalFileDisposition,
        cleanupPathEntryIdentity: TextBoxPreparedLocalFileIdentity?,
        displayName: String?
    ) {
        self.fileURL = fileURL
        let fallbackDisplayName = fileURL.lastPathComponent.isEmpty
            ? fileURL.path
            : fileURL.lastPathComponent
        if let displayName {
            let trimmedDisplayName = displayName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            self.displayName = trimmedDisplayName.isEmpty
                ? fallbackDisplayName
                : trimmedDisplayName
        } else {
            self.displayName = fallbackDisplayName
        }
        self.thumbnailPixelData = thumbnailPixelData
        self.thumbnailPixelWidth = thumbnailPixelWidth
        self.thumbnailPixelHeight = thumbnailPixelHeight
        self.thumbnailBytesPerRow = thumbnailBytesPerRow
        self.localFileDisposition = localFileDisposition
        self.cleanupPathEntryIdentity = cleanupPathEntryIdentity
    }

    private func disposeOwnedLocalFileSynchronouslyIfNeeded() {
        Self.disposeOwnedLocalFileIfIdentityMatches(
            at: fileURL,
            disposition: localFileDisposition,
            identity: cleanupPathEntryIdentity
        )
    }

    /// Disposes cmux-owned storage on a concurrent executor even when the
    /// request that produced this value has already been cancelled.
    #if compiler(>=6.2)
    @concurrent
    #endif
    func disposeOwnedLocalFileIfNeededOffMainActor() async {
        #if compiler(>=6.2)
        disposeOwnedLocalFileSynchronouslyIfNeeded()
        #else
        await Task.detached(priority: .utility) { [self] in
            self.disposeOwnedLocalFileSynchronouslyIfNeeded()
        }.value
        #endif
    }

    private static let snapshotHelperTimeout: TimeInterval = 30
    static let snapshotHelperCommand = "__textbox-attachment-snapshot-v1"
    static let snapshotHelperFrameMagic = Data("CMUXATT1".utf8)
    static let snapshotHelperMaximumPathBytes = 64 << 10
    private static let snapshotHelperQuarantine =
        CmuxConfigActionCatalogProcessQuarantine(
            generalCapacity: 4,
            globalCapacity: 1
        )

    /// Snapshots a command-palette attachment in a killable bundled helper.
    ///
    /// Both local and remote submissions use the immutable app-owned snapshot.
    /// The helper contains every potentially blocking operation on the
    /// caller-controlled path; the app only opens its own local staging file.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func prepareForTextBoxRequest(
        fileURL: URL,
        uploadTarget: TerminalImageTransferTarget
    ) async -> TextBoxPreparedFileAttachment? {
        guard fileURL.isFileURL else { return nil }
        let standardizedFileURL = fileURL.standardizedFileURL
        let sourcePath = standardizedFileURL.path
        guard sourcePath.utf8.count
                <= snapshotHelperMaximumPathBytes,
              !sourcePath.utf8.contains(0),
              (sourcePath as NSString).isAbsolutePath,
              !Task.isCancelled else {
            return nil
        }

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-textbox-snapshot-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let stagingURL = stagingDirectory
            .appendingPathComponent("snapshot", isDirectory: false)
        guard let executablePath = Bundle.main.resourceURL?
            .appendingPathComponent("bin/cmux", isDirectory: false).path else {
            return nil
        }
        let quarantineKey = UUID().uuidString
        guard let quarantineLease = await snapshotHelperQuarantine.reserve(
            key: quarantineKey,
            lane: .general
        ) else {
            return nil
        }
        let launch = CmuxConfigActionCatalogProcessReader.LaunchSpecification(
            executablePath: executablePath,
            arguments: [
                executablePath,
                snapshotHelperCommand,
                sourcePath,
                stagingURL.path,
                String(TextBoxDraftAttachmentStorageQuotaLimits.maximumFileBytes),
            ],
            environment: [
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin",
            ]
        )
        let session = CmuxConfigActionCatalogProcessSession(
            launch: launch,
            timeout: snapshotHelperTimeout,
            terminationGrace: 0.2,
            postKillHandoffDelay: 0.2,
            maximumOutputBytes:
                snapshotHelperFrameMagic.count,
            timing: .continuous,
            processOperations: .live,
            quarantine: snapshotHelperQuarantine,
            quarantineLease: quarantineLease
        )
        let helperResult = await session.run()
        switch helperResult {
        case .quarantined:
            // The session owns the lease until a late reap. Its process group
            // has already received SIGKILL, so removing the staging pathname
            // cannot expose partial bytes to the app.
            return nil
        case .completed(let frame):
            await snapshotHelperQuarantine.release(quarantineLease)
            guard frame == snapshotHelperFrameMagic,
                  !Task.isCancelled else {
                return nil
            }
        }

        let displayName = standardizedFileURL.lastPathComponent.isEmpty
            ? standardizedFileURL.path
            : standardizedFileURL.lastPathComponent
        return prepareFromOwnedStagingSnapshot(
            stagingURL,
            displayName: displayName,
            uploadTarget: uploadTarget
        )
    }

    private static func prepareFromOwnedStagingSnapshot(
        _ stagingURL: URL,
        displayName: String,
        uploadTarget: TerminalImageTransferTarget
    ) -> TextBoxPreparedFileAttachment? {
        _ = uploadTarget
        let descriptor = stagingURL.withUnsafeFileSystemRepresentation {
            path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              isRegularFile(metadata),
              metadata.st_size >= 0,
              metadata.st_size
                <= TextBoxDraftAttachmentStorageQuotaLimits.maximumFileBytes,
              let snapshotURL = TextBoxAttachment.makeOwnedRemoteUploadSnapshot(
                fromValidatedDescriptor: descriptor,
                byteCount: metadata.st_size,
                displayName: displayName
              ) else {
            return nil
        }
        guard let snapshotIdentity =
                TextBoxPreparedLocalFileIdentity.capture(at: snapshotURL) else {
            TextBoxAttachment.disposePreparedLocalFileIfNeeded(
                at: snapshotURL,
                disposition: .cmuxDraftCopy
            )
            return nil
        }
        guard !Task.isCancelled else {
            disposeOwnedLocalFileIfIdentityMatches(
                at: snapshotURL,
                disposition: .cmuxDraftCopy,
                identity: snapshotIdentity
            )
            return nil
        }
        return TextBoxPreparedFileAttachment(
            fileURL: snapshotURL,
            thumbnailPixelData: nil,
            thumbnailPixelWidth: 0,
            thumbnailPixelHeight: 0,
            thumbnailBytesPerRow: 0,
            localFileDisposition: .cmuxDraftCopy,
            cleanupPathEntryIdentity: snapshotIdentity,
            displayName: displayName
        )
    }

    #if DEBUG
    private static let thumbnailMaximumPixelSize = 512
    private static let maximumThumbnailSourceBytes = 32 * 1024 * 1024

    /// Test-only coverage for the former in-process preparation behavior.
    /// Product attachment entrypoints always use the killable helper above.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func prepare(
        fileURL: URL,
        uploadTarget: TerminalImageTransferTarget = .local,
        afterDescriptorValidation: @escaping @Sendable () -> Void = {}
    ) async -> TextBoxPreparedFileAttachment? {
        #if compiler(>=6.2)
        prepareSynchronously(
            fileURL: fileURL,
            uploadTarget: uploadTarget,
            afterDescriptorValidation: afterDescriptorValidation
        )
        #else
        await Task.detached(priority: .userInitiated) {
            prepareSynchronously(
                fileURL: fileURL,
                uploadTarget: uploadTarget,
                afterDescriptorValidation: afterDescriptorValidation
            )
        }.value
        #endif
    }

    private static func prepareSynchronously(
        fileURL: URL,
        uploadTarget: TerminalImageTransferTarget,
        afterDescriptorValidation: @Sendable () -> Void
    ) -> TextBoxPreparedFileAttachment? {
        guard fileURL.isFileURL else { return nil }

        let openedFile = fileURL.withUnsafeFileSystemRepresentation {
            path -> (descriptor: Int32, pathEntryIdentity: TextBoxPreparedLocalFileIdentity)? in
            guard let path else { return nil }

            var metadata = stat()
            guard Darwin.lstat(path, &metadata) == 0,
                  isRegularFile(metadata) || isSymbolicLink(metadata) else {
                return nil
            }

            let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            return (descriptor, TextBoxPreparedLocalFileIdentity(metadata))
        }
        guard let openedFile else { return nil }
        let descriptor = openedFile.descriptor
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              isRegularFile(metadata) else {
            return nil
        }

        let standardizedFileURL = fileURL.standardizedFileURL
        let originalDisplayName = standardizedFileURL.lastPathComponent.isEmpty
            ? standardizedFileURL.path
            : standardizedFileURL.lastPathComponent
        let sourceDisposition =
            TextBoxAttachment.localFileDispositionForBackgroundPreparation(
                standardizedFileURL
            )
        afterDescriptorValidation()
        guard !Task.isCancelled else { return nil }

        let thumbnail = preparedThumbnail(
            descriptor: descriptor,
            fileSize: metadata.st_size,
            fileURL: fileURL
        )
        let preparedFileURL: URL
        let preparedDisposition: TextBoxPreparedLocalFileDisposition
        let preparedCleanupIdentity: TextBoxPreparedLocalFileIdentity?
        switch uploadTarget {
        case .local, .unknown:
            preparedFileURL = standardizedFileURL
            if sourceDisposition.cleanupLocalURLWhenDisposed,
               !openedFile.pathEntryIdentity.stillNamesEntry(
                   at: standardizedFileURL
               ) {
                TextBoxAttachment.handlePreparedLocalFileIdentityMismatch(
                    at: standardizedFileURL,
                    disposition: sourceDisposition
                )
                preparedDisposition = .callerOwned
                preparedCleanupIdentity = nil
            } else {
                preparedDisposition = TextBoxAttachment.prepareLocalFileForBackgroundInsertion(
                    standardizedFileURL,
                    capturedDisposition: sourceDisposition
                )
                preparedCleanupIdentity =
                    preparedDisposition.cleanupLocalURLWhenDisposed
                    ? openedFile.pathEntryIdentity
                    : nil
            }
        case .remote:
            guard let snapshotURL = TextBoxAttachment.makeOwnedRemoteUploadSnapshot(
                fromValidatedDescriptor: descriptor,
                byteCount: metadata.st_size,
                displayName: originalDisplayName
            ) else {
                return nil
            }
            guard let snapshotIdentity =
                    TextBoxPreparedLocalFileIdentity.capture(at: snapshotURL) else {
                TextBoxAttachment.disposePreparedLocalFileIfNeeded(
                    at: snapshotURL,
                    disposition: .cmuxDraftCopy
                )
                return nil
            }
            guard !Task.isCancelled else {
                disposeOwnedLocalFileIfIdentityMatches(
                    at: snapshotURL,
                    disposition: .cmuxDraftCopy,
                    identity: snapshotIdentity
                )
                return nil
            }
            preparedFileURL = snapshotURL
            preparedDisposition = .cmuxDraftCopy
            preparedCleanupIdentity = snapshotIdentity
            disposeOwnedLocalFileIfIdentityMatches(
                at: standardizedFileURL,
                disposition: sourceDisposition,
                identity: openedFile.pathEntryIdentity
            )
        }
        return TextBoxPreparedFileAttachment(
            fileURL: preparedFileURL,
            thumbnailPixelData: thumbnail?.pixelData,
            thumbnailPixelWidth: thumbnail?.width ?? 0,
            thumbnailPixelHeight: thumbnail?.height ?? 0,
            thumbnailBytesPerRow: thumbnail?.bytesPerRow ?? 0,
            localFileDisposition: preparedDisposition,
            cleanupPathEntryIdentity: preparedCleanupIdentity,
            displayName: originalDisplayName
        )
    }
    #endif

    private static func disposeOwnedLocalFileIfIdentityMatches(
        at fileURL: URL,
        disposition: TextBoxPreparedLocalFileDisposition,
        identity: TextBoxPreparedLocalFileIdentity?
    ) {
        guard disposition.cleanupLocalURLWhenDisposed,
              let identity else {
            return
        }
        guard identity.stillNamesEntry(at: fileURL) else {
            TextBoxAttachment.handlePreparedLocalFileIdentityMismatch(
                at: fileURL,
                disposition: disposition
            )
            return
        }
        TextBoxAttachment.disposePreparedLocalFileIfNeeded(
            at: fileURL,
            disposition: disposition
        )
    }

    private static func isRegularFile(_ metadata: stat) -> Bool {
        (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    #if DEBUG
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
    #endif
}
