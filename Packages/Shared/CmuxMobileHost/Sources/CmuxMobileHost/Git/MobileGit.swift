/// The git family on this Mac (c13-viewers.md): read-only `git.status` and
/// `git.diff` over the files policy's roots. Register next to `MobileFiles`
/// with the same configuration and roots, and offer `MobileGit.cap` in
/// `MobileHostConfiguration.caps`.
public struct MobileGit: Sendable {
    /// The `hello.ok` cap that tells the phone the family is served.
    public static let cap = "git.read"

    public let files: MobileFilesConfiguration
    public let configuration: MobileGitConfiguration
    public let roots: any MobileFileRootsProvider
    public let reader: any MobileGitReader

    public init(files: MobileFilesConfiguration, configuration: MobileGitConfiguration = MobileGitConfiguration(),
                roots: any MobileFileRootsProvider, reader: any MobileGitReader) {
        self.files = files
        self.configuration = configuration
        self.roots = roots
        self.reader = reader
    }

    /// Over the same configuration and roots as the host's files family.
    public init(sharing files: MobileFiles, configuration: MobileGitConfiguration = MobileGitConfiguration(),
                reader: any MobileGitReader) {
        self.init(files: files.configuration, configuration: configuration, roots: files.roots, reader: reader)
    }

    /// `handlers` plus the `git.status` and `git.diff` reads.
    public func registering(into handlers: MobileChannelHandlers = MobileChannelHandlers()) -> MobileChannelHandlers {
        var reads = handlers.reads
        reads["git.status"] = GitStatusReadHandler(files: files, roots: roots, reader: reader)
        reads["git.diff"] = GitDiffReadHandler(files: files, configuration: configuration, roots: roots, reader: reader)
        return MobileChannelHandlers(channels: handlers.channels, reads: reads)
    }
}
