import CmuxMobileWire

/// The files family on this Mac (c4-files.md): register its handlers into
/// the host's `MobileChannelHandlers`. One instance per `MobileHost`, so all
/// sessions share the upload staging (one live upload per partial).
public struct MobileFiles: Sendable {
    public let configuration: MobileFilesConfiguration
    public let roots: any MobileFileRootsProvider
    private let staging: UploadStaging

    public init(configuration: MobileFilesConfiguration = .standard, roots: any MobileFileRootsProvider = StaticFileRoots()) {
        self.configuration = configuration
        self.roots = roots
        staging = UploadStaging(configuration: configuration)
    }

    /// `handlers` plus `files.upload`, `files.download`, `files.list` and `files.roots`.
    public func registering(into handlers: MobileChannelHandlers = MobileChannelHandlers()) -> MobileChannelHandlers {
        var channels = handlers.channels
        var reads = handlers.reads
        channels[.filesUpload] = FilesUploadHandler(configuration: configuration, roots: roots, staging: staging)
        channels[.filesDownload] = FilesDownloadHandler(configuration: configuration, roots: roots)
        reads["files.list"] = FilesListReadHandler(configuration: configuration, roots: roots)
        reads["files.roots"] = FilesRootsReadHandler(configuration: configuration, roots: roots)
        return MobileChannelHandlers(channels: channels, reads: reads)
    }
}
