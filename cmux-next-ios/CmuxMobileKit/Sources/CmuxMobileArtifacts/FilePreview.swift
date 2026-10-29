import Foundation

/// A file the phone already holds (a composer or message attachment), as a
/// preview reads it.
public struct LocalFile: Hashable, Sendable {
    public var id: String
    public var name: String
    public var data: Data?
    /// A photo (decoded as an image whatever its name says).
    public var isImage: Bool
    /// A local copy, when the bytes live on disk (a picked video).
    public var fileURL: URL?

    public init(id: String, name: String, data: Data?, isImage: Bool, fileURL: URL? = nil) {
        self.id = id
        self.name = name
        self.data = data
        self.isImage = isImage
        self.fileURL = fileURL
    }

    /// The reference its preview goes by: unique per attachment, ending in its name.
    public var reference: String { LocalFileArtifactSource.scheme + id + "/" + name }

    /// What kind of preview it gets: by its name's extension, an image for a
    /// photo, Quick Look (or Share) for anything else.
    public var kind: TerminalArtifact.Kind {
        if isImage { return .image }
        let ext = (name as NSString).pathExtension
        return TerminalArtifact.kind(forExtension: ext) ?? .binary
    }

    public var artifact: TerminalArtifact { TerminalArtifact(reference: reference, kind: kind, detail: "Attached") }
}

/// Serves attachments the phone holds, decoded as the Mac's files are
/// (`LinkFileArtifactSource.content`), and anything else from `fallback`.
public struct LocalFileArtifactSource: ArtifactSource {
    /// The prefix of a local attachment's reference (never a path on the Mac).
    public static let scheme = "attachment:"

    let files: [String: LocalFile]
    let fallback: any ArtifactSource
    /// Reads the bytes of a file the phone names but does not hold (a recorded prompt's image).
    let fetch: (@Sendable (LocalFile) async -> Data?)?

    public init(files: [LocalFile], fallback: any ArtifactSource = UnavailableArtifactSource(),
                fetch: (@Sendable (LocalFile) async -> Data?)? = nil) {
        var byReference: [String: LocalFile] = [:]
        for file in files { byReference[file.reference] = file }
        self.files = byReference
        self.fallback = fallback
        self.fetch = fetch
    }

    public func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent {
        guard let file = files[artifact.reference] else { return try await fallback.load(artifact) }
        if let url = file.fileURL, file.data == nil {
            return artifact.kind == .video ? .file(url) : .quickLook(url)
        }
        var data = file.data
        if data == nil, let fetch {
            data = await fetch(file)
            // The Mac holds it: say so, not that the phone lost it.
            guard data != nil else { throw ArtifactUnavailable("Connect to your Mac to see \(file.name).") }
        }
        guard let data else { throw ArtifactUnavailable("\(file.name) isn't on this iPhone anymore.") }
        return try LinkFileArtifactSource.content(for: artifact, data: data)
    }
}

/// Files to open full screen: swipe between them, Share or Save each.
public struct FilePreviewRequest: Identifiable {
    public let id = UUID()
    public let artifacts: [TerminalArtifact]
    public let source: any ArtifactSource
    public let start: Int

    public init(artifacts: [TerminalArtifact], source: any ArtifactSource, start: Int = 0) {
        self.artifacts = artifacts
        self.source = source
        self.start = artifacts.indices.contains(start) ? start : 0
    }

    /// Attachments the phone holds, opened at `start`'s id.
    public init(files: [LocalFile], startingAt start: String?, fallback: any ArtifactSource = UnavailableArtifactSource(),
                fetch: (@Sendable (LocalFile) async -> Data?)? = nil) {
        self.init(artifacts: files.map(\.artifact), source: LocalFileArtifactSource(files: files, fallback: fallback, fetch: fetch),
                  start: files.firstIndex { $0.id == start } ?? 0)
    }

    /// One file on the Mac (or a link), read over the link's `file` service by `source`.
    public init(reference: String, source: any ArtifactSource, line: Int? = nil) {
        self.init(artifacts: [Self.artifact(for: reference, line: line)], source: source)
    }

    /// A reference as a preview reads it: a link, or a file by its extension (text when unknown).
    public static func artifact(for reference: String, line: Int? = nil) -> TerminalArtifact {
        if reference.hasPrefix("http://") || reference.hasPrefix("https://") {
            return TerminalArtifact(reference: reference, kind: .link)
        }
        let ext = (reference as NSString).pathExtension
        let kind = TerminalArtifact.kind(forExtension: ext) ?? (reference.hasSuffix("/") ? .directory : ext.isEmpty ? .text : .binary)
        return TerminalArtifact(reference: reference, kind: kind, line: line)
    }
}

/// A link in an agent's answer that names a file (a path, `file://`, or
/// `path:line`), as opposed to a web page or another app's link.
public struct FileLink: Equatable, Sendable {
    /// The path as written (relative ones resolve against the session's folder).
    public let reference: String
    public let line: Int?

    /// Schemes the system opens (Safari, Mail, Phone, Messages).
    static let systemSchemes: Set<String> = ["http", "https", "mailto", "tel", "sms", "facetime"]

    /// nil for a web or app link (the system opens it).
    public init?(url: URL) {
        var raw: String
        var line: Int?
        let scheme = url.scheme?.lowercased()
        if scheme == "file" {
            raw = url.path(percentEncoded: false)
            if let fragment = url.fragment, fragment.hasPrefix("L") { line = Int(fragment.dropFirst().prefix { $0.isNumber }) }
        } else if let scheme, !Self.isPathLike(scheme: scheme, url: url) {
            // A web page or another app's link (maps:, shortcuts:, x-apple-…:).
            return nil
        } else {
            // No scheme, or "name.ext:12" read as one: the whole link is the path.
            raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        }
        guard !raw.hasPrefix("#") else { return nil }
        if let hash = raw.range(of: "#L", options: .backwards) {
            line = Int(raw[hash.upperBound...].prefix { $0.isNumber })
            raw = String(raw[..<hash.lowerBound])
        }
        // `path:12` or `path:12:4`.
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 2, let number = Int(parts[1]), parts.dropFirst().allSatisfy({ Int($0) != nil }) {
            line = line ?? number
            raw = String(parts[0])
        }
        guard !raw.isEmpty, raw != "/" else { return nil }
        reference = raw
        self.line = line
    }

    /// A "scheme" that is really a file name read as one: `README.md:12`
    /// (a dot in it) or `Makefile:3` (only digits after it).
    static func isPathLike(scheme: String, url: URL) -> Bool {
        if systemSchemes.contains(scheme) || url.absoluteString.contains("://") { return false }
        if scheme.contains(".") { return true }
        let rest = url.absoluteString.dropFirst(scheme.count + 1)
        return !rest.isEmpty && rest.split(separator: ":").allSatisfy { Int($0) != nil }
    }
}

#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// Full-screen previews of one or more files (`ArtifactPreview` each): page
/// sideways between them, Close or swipe an image down to close.
public struct FilePreviewGallery: View {
    let request: FilePreviewRequest
    /// Closes a preview UIKit presented; nil: the SwiftUI presentation's dismiss.
    let onClose: (() -> Void)?
    @State private var selection: Int
    @Environment(\.dismiss) private var dismiss

    public init(request: FilePreviewRequest, onClose: (() -> Void)? = nil) {
        self.request = request
        self.onClose = onClose
        _selection = State(initialValue: request.start)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    public var body: some View {
        Group {
            if request.artifacts.count > 1 {
                TabView(selection: $selection) {
                    ForEach(Array(request.artifacts.enumerated()), id: \.offset) { index, artifact in
                        page(artifact, index: index).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            } else if let artifact = request.artifacts.first {
                page(artifact, index: 0)
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .accessibilityIdentifier("file.preview")
        // VoiceOver stays inside the preview while it is open.
        .accessibilityAddTraits(.isModal)
    }

    private func page(_ artifact: TerminalArtifact, index: Int) -> some View {
        FilePreviewPage(artifact: artifact, source: request.source, position: (index, request.artifacts.count), onClose: close)
    }
}

/// One page of the gallery: its own Preview/Source choice and folder stack.
private struct FilePreviewPage: View {
    let artifact: TerminalArtifact
    let source: any ArtifactSource
    let position: (index: Int, count: Int)
    let onClose: () -> Void
    @State private var showSource = false

    var body: some View {
        NavigationStack {
            ArtifactPreview(artifact: artifact, source: source, showSource: $showSource, position: position, onClose: onClose)
                .navigationDestination(for: TerminalArtifact.self) { child in
                    ArtifactPreview(artifact: child, source: source, showSource: $showSource)
                }
        }
    }
}

extension FilePreviewRequest {
    /// Presents the preview full screen from UIKit (where a SwiftUI cover would
    /// disturb the presenter's keyboard layout guide, as in the terminal).
    @MainActor
    public func present(from presenter: UIViewController) {
        // Dismissing from the presenter closes the preview (and a share sheet over it).
        let gallery = FilePreviewGallery(request: self) { [weak presenter] in presenter?.dismiss(animated: true) }
        let controller = UIHostingController(rootView: gallery)
        controller.modalPresentationStyle = .fullScreen
        presenter.present(controller, animated: true)
    }
}

extension View {
    /// Opens `request`'s files full screen while it is set.
    public func filePreview(_ request: Binding<FilePreviewRequest?>) -> some View {
        fullScreenCover(item: request) { FilePreviewGallery(request: $0) }
    }
}
#endif
