import CmuxLink
import CmuxMobileWire

/// The files family on this Mac (c4-files.md): register its handlers into
/// the host's `MobileChannelHandlers`. One instance per `MobileHost`, so all
/// sessions share the upload staging (one live upload per partial). The
/// app builds the configuration from the signed-in user's home at its
/// composition root.
public struct MobileFiles: Sendable {
    public let configuration: MobileFilesConfiguration
    public let roots: any MobileFileRootsProvider
    private let staging: UploadStaging
    private let limiter: FilesChannelLimiter
    private let clock: LinkClock

    public init(configuration: MobileFilesConfiguration, roots: any MobileFileRootsProvider = StaticFileRoots(),
                clock: LinkClock = .continuous) {
        self.configuration = configuration
        self.roots = roots
        self.clock = clock
        staging = UploadStaging(configuration: configuration)
        limiter = FilesChannelLimiter(limit: configuration.maxChannelsPerDevice)
    }

    /// `handlers` plus `files.upload`, `files.download`, `files.list` and `files.roots`.
    public func registering(into handlers: MobileChannelHandlers = MobileChannelHandlers()) -> MobileChannelHandlers {
        var channels = handlers.channels
        var reads = handlers.reads
        channels[.filesUpload] = FilesUploadHandler(configuration: configuration, roots: roots, staging: staging, limiter: limiter)
        channels[.filesDownload] = FilesDownloadHandler(configuration: configuration, roots: roots, limiter: limiter, clock: clock)
        reads["files.list"] = FilesListReadHandler(configuration: configuration, roots: roots)
        reads["files.roots"] = FilesRootsReadHandler(configuration: configuration, roots: roots)
        return MobileChannelHandlers(channels: channels, reads: reads)
    }
}
