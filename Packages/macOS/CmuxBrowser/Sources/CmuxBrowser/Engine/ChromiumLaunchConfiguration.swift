import Foundation

/// Input to the Chromium child-process argument builder.
struct ChromiumLaunchConfiguration: Equatable, Sendable {
    var executableURL: URL
    var profileDirectory: URL
    var debuggingTransport: ChromiumDebuggingTransport
    var viewportWidth: Int
    var viewportHeight: Int
    var extensionDirectories: [URL]
    var additionalArguments: [String]

    init(
        executableURL: URL,
        profileDirectory: URL,
        debuggingTransport: ChromiumDebuggingTransport = .pipe,
        viewportWidth: Int = 1280,
        viewportHeight: Int = 800,
        extensionDirectories: [URL] = [],
        additionalArguments: [String] = []
    ) {
        self.executableURL = executableURL
        self.profileDirectory = profileDirectory
        self.debuggingTransport = debuggingTransport
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.extensionDirectories = extensionDirectories
        self.additionalArguments = additionalArguments
    }
}
