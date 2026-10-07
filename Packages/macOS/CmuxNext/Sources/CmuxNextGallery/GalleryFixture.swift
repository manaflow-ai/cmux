public import Foundation

/// A fixture file of a gallery variant: JSON of a real model, in the owning package's resources,
/// named by its repo-relative path so the web gallery reads the same file
/// (`schemas/gallery/fixtures.json` lists the roots both hosts read).
public nonisolated struct GalleryFixture: Hashable, Sendable {
    /// The file as the web entry names it: a path from the repository root.
    public let repoPath: String
    /// The bundled copy.
    public let url: URL?

    /// A fixture in `bundle` (the owning package's `Bundle.module`).
    ///
    /// - Parameters:
    ///   - name: The file name without `.json` (the variant's name, by convention).
    ///   - bundle: The package's resource bundle.
    ///   - subdirectory: The resource folder; `Fixtures` by convention.
    ///   - repoPath: The file's path from the repository root.
    public init(_ name: String, in bundle: Bundle, subdirectory: String? = "Fixtures", repoPath: String) {
        self.repoPath = repoPath
        url = bundle.url(forResource: name, withExtension: "json", subdirectory: subdirectory)
            ?? bundle.url(forResource: name, withExtension: "json")
    }

    /// The file's bytes.
    public func data() throws -> Data {
        guard let url else { throw GalleryError(message: "fixture \(repoPath) is not in the bundle") }
        return try Data(contentsOf: url)
    }

    /// The file decoded as `type`.
    public func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: data())
    }
}

/// Why a gallery view could not be built or registered.
public nonisolated struct GalleryError: Error, Hashable, Sendable, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}
